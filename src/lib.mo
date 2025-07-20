import IcrcReader "./reader";
import IcrcSender "./sender";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Map "mo:map/Map";
import Blob "mo:base/Blob";
import Result "mo:base/Result";
import Option "mo:base/Option";
import ICRCLedger "./icrc_ledger";
import Debug "mo:base/Debug";
import SWB "mo:swb";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Ver1 "./memory/v1";
import MU "mo:mosup";
import Int "mo:base/Int";
import Time "mo:base/Time";

module {
    type R<A, B> = Result.Result<A, B>;

    public module Mem {
        public module Ledger {
            public let V1 = Ver1.Ledger;
        };
    };

    /// No other errors are currently possible
    public type SendError = {
        #InsufficientFunds;
        #InvalidSubaccount;
        #InvalidMemo;
        #UnsupportedAccount;
    };

    let VM = Mem.Ledger.V1;

    public type Meta = VM.Meta;

    public func subaccountToBlob(s : ?Blob) : Blob {
        let ?a = s else return Blob.fromArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        a;
    };

    /// Info about local ledger params returned by getInfo
    public type Info = {
        last_indexed_tx : Nat;
        accounts : Nat;
        pending : Nat;
        actor_principal : Principal;
        sender_instructions_cost : Nat64;
        reader_instructions_cost : Nat64;
        errors : Nat;
        lastTxTime : Nat64;
    };



    public type AccountMixed = {
        #icrc : ICRCLedger.Account;
        #icp : Blob;
    };

    public type Transfer = {
        to : ICRCLedger.Account;
        fee : ?Nat;
        from : AccountMixed;
        memo : ?Blob;
        created_at_time : ?Nat64;
        amount : Nat;
        spender : ?AccountMixed;
    };

    /// The ledger class
    /// start_from_block should be in most cases #last (starts from the last block when first started)
    /// if something went wrong and you need to reinstall the canister
    /// or use the library with a canister that already has tokens inside it's subaccount balances
    /// you can set start_from_block to a specific block number from which you want to start reading the ledger when reinstalled
    /// you will have to remove all onRecieve, onSent, onMint, onBurn callbacks and set them again
    /// (or they could try to make calls based on old transactions)
    ///
    /// Example:
    /// ```motoko
    ///     stable let lmem = L.LMem();
    ///     let ledger = L.Ledger(lmem, "bnz7o-iuaaa-aaaaa-qaaaa-cai", #last);
    /// ```
    public class Ledger<system>(xmem : MU.MemShell<VM.Mem>, ledger_id_txt : Text, start_from_block : ({ #id : Nat; #last }), me_can : Principal) {
        let lmem = MU.access(xmem);
        let ledger_id = Principal.fromText(ledger_id_txt);
        let errors = SWB.SlidingWindowBuffer<Text>();

        var sender_instructions_cost : Nat64 = 0;
        var reader_instructions_cost : Nat64 = 0;

        var callback_onReceive : ?((Transfer) -> ()) = null;
        var callback_onSent : ?((Nat64, Nat) -> ()) = null;

        private func trap(e:Text) : None {
            Debug.print("TRAP:" # e);
            Debug.trap(e);
        };

        // Sender

        private func logErr(e : Text) : () {
            let idx = errors.add(e);
            if ((1 +idx) % 300 == 0) {
                // every 300 elements
                errors.delete(errors.len() - 100) // delete all but the last 100
            };
        };


        public func getMinter() : (?ICRCLedger.Account) {
            let ?m = lmem.meta else return null;
            m.minter;
        };


        public func genNextSendId(t: ?Nat64) : Nat64 {
            let created_at_time = (Option.get(t, Nat64.fromNat(Int.abs(Time.now())))/1_000_000_000)*1_000_000_000;
            

            let id = created_at_time + lmem.next_tx_id;
            lmem.next_tx_id += 1;
            if (lmem.next_tx_id >= 1_000_000_000) lmem.next_tx_id := 0;
            return id;
        };


        let icrc_sender = IcrcSender.Sender<system>({
            ledger_id;
            xmem = lmem.sender;
            getFee = func() : Nat {
                let ?m = lmem.meta else trap("ERR100");
                m.fee;
            };
            onError = logErr; // In case a cycle throws an error
            onConfirmations = func(confirmations : [(Nat64, Nat)]) {
                // handle confirmed ids after sender
                for (idx in confirmations.keys()) {
                    let (id, block_id) = confirmations[idx];
                    ignore do ? { callback_onSent!(id, block_id) };
                };
            };
            getMinter = getMinter;
            onCycleEnd = func(i : Nat64) { sender_instructions_cost := i }; // used to measure how much instructions it takes to send transactions in one cycle
            me_can;
            genNextSendId;
        });



        public func getMeta() : VM.Meta {
            let ?m = lmem.meta else trap("ERR101");
            m;
        };

        private func handle_incoming_amount(subaccount : ?Blob, amount : Nat) : () {
            switch (Map.get<Blob, VM.AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount))) {
                case (?acc) {
                    acc.balance += amount : Nat;
                };
                case (null) {
                    Map.set(
                        lmem.accounts,
                        Map.bhash,
                        subaccountToBlob(subaccount),
                        {
                            var balance = amount;
                            var in_transit = 0;
                        },
                    );
                };
            };
        };

        private func handle_outgoing_amount(subaccount : ?Blob, amount : Nat) : () {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return;

                acc.balance -= amount : Nat;
            

            // When replaying the ledger we don't have in_transit and it results in natural substraction underflow.
            // since in_transit is local and added when sending
            // we have to ignore if it when replaying
            // Also if for some reason devs decide to send funds with something else than this library, it will also be an amount that is not in transit
            if (acc.in_transit < amount) {
                acc.in_transit := 0;
            } else {
                acc.in_transit -= amount : Nat;
            };

            if (acc.balance == 0 and acc.in_transit == 0) {
                ignore Map.remove<Blob, VM.AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount));
            };

        };
        
        let nullSubaccount:Blob = subaccountToBlob(null);
        // Usually we don't return 32 zeroes but null
        private func formatSubaccount(s: ?Blob) : ?Blob {
            switch(s) {
                case (null) null;
                case (?s) {
                    if (s == nullSubaccount) null else ?s;
                };
            };
        };

        // Reader
        let icrc_reader = IcrcReader.Reader<system>({
            maxSimultaneousRequests = 20;
            xmem = lmem.reader;
            ledger_id;
            start_from_block;
            readingEnabled = func() : Bool {
                let ?m = lmem.meta else return false;
                m.minter != null;
            };
            onError = logErr; // In case a cycle throws an error
            onCycleEnd = func(i : Nat64) { reader_instructions_cost := i }; // returns the instructions the cycle used.
            // It can include multiple calls to onRead
            onRead = func(transactions : [IcrcReader.Transaction], start_id:Nat) {
                icrc_sender.confirm(transactions, start_id);


                label txloop for (tx in transactions.vals()) {
                    if (not Option.isNull(tx.mint)) {
                        let ?mint = tx.mint else continue txloop;
                        if (mint.to.owner == me_can) {
                            handle_incoming_amount(formatSubaccount(mint.to.subaccount), mint.amount);

                            let minter_from = Option.get(getMinter(), {owner = Principal.fromText("aaaaa-aa"); subaccount = null});
                            ignore do ? { 
                                callback_onReceive!(
                                {
                                    mint with
                                    from = #icrc(minter_from); // We can't recieve mint without the ledger having a minter account
                                    spender = null;
                                    fee = null;
                                } : Transfer
                            );
                            };
                            
                        };
                    };
                    if (not Option.isNull(tx.transfer)) {
                        let ?tr = tx.transfer else continue txloop;
                        let ?fee = tr.fee else continue txloop;
                        if (tr.to.owner == me_can) {
                            if (tr.amount >= fee) {
                                // ignore it since we can't even burn that
                                handle_incoming_amount(formatSubaccount(tr.to.subaccount), tr.amount);
                                ignore do ? {
                                    callback_onReceive! ({
                                        tr with
                                        from = #icrc(tr.from);
                                        spender = do ? { #icrc(tr.spender!) };
                                    });
                                };
                            };
                        };

                        if (tr.from.owner == me_can) {
                            handle_outgoing_amount(formatSubaccount(tr.from.subaccount), tr.amount + fee);
                        };
                    };
                    if (not Option.isNull(tx.burn)) {
                        let ?burn = tx.burn else continue txloop;
                        if (burn.from.owner == me_can) {
                            handle_outgoing_amount(formatSubaccount(burn.from.subaccount), burn.amount);
                        };
                    };
                };
            };
        });

        icrc_sender.setGetReaderLastUpdate(icrc_reader.getReaderLastUpdate);

        /// Start the ledger timers

        private func retrieveMeta() : async () {
            let ledger = actor (Principal.toText(ledger_id)) : ICRCLedger.Self;
            let symbol = await ledger.icrc1_symbol();
            let decimals = await ledger.icrc1_decimals();
            let minter = await ledger.icrc1_minting_account();
            let name = await ledger.icrc1_name();
            let fee = await ledger.icrc1_fee();
            lmem.meta := ?{ symbol; decimals; minter; fee; name };
        };

        /// Returns the actor principal
        public func me() : Principal {
            me_can
        };

        /// Returns the errors that happened
        public func getErrors() : [Text] {
            let start = errors.start();
            Array.tabulate<Text>(
                errors.len(),
                func(i : Nat) {
                    let ?x = errors.getOpt(start + i) else trap("memory corruption");
                    x;
                },
            );
        };

   

        /// Returns info about ledger library
        public func getInfo() : Info {
            {
                last_indexed_tx = icrc_reader.getLastReadTxIndex();
                accounts = Map.size(lmem.accounts);
                pending = icrc_sender.getPendingCount();
                actor_principal = me_can;
                sent = lmem.next_tx_id;
                reader_instructions_cost;
                sender_instructions_cost;
                errors = errors.len();
                lastTxTime = icrc_reader.getReaderLastTxTime();
            };
        };

        /// Get Iter of all accounts owned by the canister (except dust < fee)
        public func accounts() : Iter.Iter<(Blob, Nat)> {
            Iter.map<(Blob, VM.AccountMem), (Blob, Nat)>(Map.entries<Blob, VM.AccountMem>(lmem.accounts), func((k, v)) { (k, v.balance - v.in_transit) });
        };

        /// Returns the fee for sending a transaction
        public func getFee() : Nat {
            let ?m = lmem.meta else trap("ERR103");
            m.fee;
        };

        /// Returns the ledger sender class
        public func getSender() : IcrcSender.Sender {
            icrc_sender;
        };

        /// Returns the ledger reader class
        public func getReader() : IcrcReader.Reader {
            icrc_reader;
        };



        /// Send a transfer from a canister owned address
        /// It's added to a queue and will be sent as soon as possible.
        /// You can send tens of thousands of transactions in one update call. It just adds them to a BTree
        public func send(tr : IcrcSender.TransactionInput) : R<Nat64, SendError> {
            // The amount we send includes the fee. meaning recepient will get the amount - fee


            // Check if from is the minter, if so we don't need to check balance and track in transit
            let ?m = lmem.meta else trap("ERR104");

            // Verify send to is valid
            switch(tr.to) {
                case (#icrc(to)) {
                    switch(to.subaccount) {
                        case (?subaccount) {
                            if (subaccount.size() != 32) return #err(#InvalidSubaccount);
                            ignore do ? { if (tr.memo!.size() > 32) return #err(#InvalidMemo)};
                        };
                        case (null) ();
                    };
                };
                case (#icp(to)) {
                    return #err(#UnsupportedAccount);
                    if (to.size() != 32) return #err(#InvalidSubaccount);
                };
            };

            let is_mint = switch(m.minter) {
                case (?m) {
                    me_can == m.owner and tr.from_subaccount == m.subaccount
                };
                case (null) {
                    false
                };
            };

            if (not is_mint) {
                let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(tr.from_subaccount)) else return #err(#InsufficientFunds);
                if (acc.balance : Nat - acc.in_transit : Nat < tr.amount) return #err(#InsufficientFunds);
                acc.in_transit += tr.amount;   
            };
            
            let id = genNextSendId(null);
    
            icrc_sender.send(id, tr);
            #ok(id);
        };

        /// Returns the balance of a subaccount owned by the canister (except dust < fee)
        /// It's different from the balance in the original ledger if sent transactions are not confirmed yet.
        /// We are keeping track of the in_transit amount.
        public func balance(subaccount : ?Blob) : Nat {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return 0;
            acc.balance - acc.in_transit;
        };

        /// Returns the internal balance in case we want to see in_transit and raw balance separately
        public func balanceInternal(subaccount : ?Blob) : (Nat, Nat) {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return (0, 0);
            (acc.balance, acc.in_transit);
        };

        /// Called when a received transaction is confirmed. Only one function can be set. (except dust < fee)
        public func onReceive(fn : (Transfer) -> ()) : () {
            assert (Option.isNull(callback_onReceive));
            callback_onReceive := ?fn;
        };

        /// Called back with the id of the confirmed transaction. The id returned from the send function. Only one function can be set.
        public func onSent(fn : (Nat64, Nat) -> ()) : () {
            assert (Option.isNull(callback_onSent));
            callback_onSent := ?fn;
        };

        /// If checking for transaction that wasn't queued yet, this function will return wrong result.
        public func isSent(id : Nat64) : Bool {
           
            icrc_sender.isSent(id);
        };

        // Here so we have the same interface as the icp ledger
        public func registerSubaccount(subaccount: ?Blob) : () {
            // do nothing
        };

        public func unregisterSubaccount(subaccount: ?Blob) : () {
            // do nothing
        };

        public func isRegisteredSubaccount(subaccount: ?Blob) : Bool {
            true;
        };

        ignore Timer.setTimer<system>(#seconds 0, retrieveMeta);
        ignore Timer.recurringTimer<system>(#seconds 3600, retrieveMeta); // every hour


    };

};
