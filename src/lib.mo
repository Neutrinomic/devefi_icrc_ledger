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
import Set "mo:map/Set";

module {
    type R<A, B> = Result.Result<A, B>;

    /// No other errors are currently possible
    public type SendError = {
        #InsufficientFunds;
    };

    /// Local account memory
    public type AccountMem = {
        var balance : Nat;
        var in_transit : Nat;
    };

    public type Mem = {
        reader : IcrcReader.Mem;
        sender : IcrcSender.Mem;
        accounts : Map.Map<Blob, AccountMem>;
        var actor_principal : ?Principal;
        var meta : ?Meta;
        var next_tx_id : Nat64;
    };

    /// Used to create new ledger memory (it's outside of the class to be able to place it in stable memory)
    public func LMem() : Mem {
        {
            reader = IcrcReader.Mem();
            sender = IcrcSender.Mem();
            accounts = Map.new<Blob, AccountMem>();
            var actor_principal = null;
            var meta = null;
            minter = null;
            var next_tx_id : Nat64 = 0;

        };
    };

    public func subaccountToBlob(s : ?Blob) : Blob {
        let ?a = s else return Blob.fromArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        a;
    };

    /// Info about local ledger params returned by getInfo
    public type Info = {
        last_indexed_tx : Nat;
        accounts : Nat;
        pending : Nat;
        actor_principal : ?Principal;
        sender_instructions_cost : Nat64;
        reader_instructions_cost : Nat64;
        errors : Nat;
        lastTxTime : Nat64;
    };

    public type Meta = {
        symbol : Text;
        decimals : Nat8;
        minter : ?ICRCLedger.Account;
        fee : Nat;
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
    public class Ledger<system>(lmem : Mem, ledger_id_txt : Text, start_from_block : ({ #id : Nat; #last })) {

        let ledger_id = Principal.fromText(ledger_id_txt);
        let errors = SWB.SlidingWindowBuffer<Text>();

        var sender_instructions_cost : Nat64 = 0;
        var reader_instructions_cost : Nat64 = 0;

        var callback_onReceive : ?((Transfer) -> ()) = null;
        var callback_onSent : ?((Nat64) -> ()) = null;

        // Sender

        var started : Bool = false;

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

        let icrc_sender = IcrcSender.Sender({
            ledger_id;
            mem = lmem.sender;
            getFee = func() : Nat {
                let ?m = lmem.meta else Debug.trap("ERR100");
                m.fee;
            };
            onError = logErr; // In case a cycle throws an error
            onConfirmations = func(confirmations : [Nat64]) {
                // handle confirmed ids after sender
                for (id in confirmations.vals()) {
                    ignore do ? { callback_onSent!(id) };
                };
            };
            getMinter = getMinter;
            onCycleEnd = func(i : Nat64) { sender_instructions_cost := i }; // used to measure how much instructions it takes to send transactions in one cycle
        });

        public func getMeta() : Meta {
            let ?m = lmem.meta else Debug.trap("ERR101");
            m;
        };

        private func handle_incoming_amount(subaccount : ?Blob, amount : Nat) : () {
            switch (Map.get<Blob, AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount))) {
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
                ignore Map.remove<Blob, AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount));
            };

        };

        // Reader
        let icrc_reader = IcrcReader.Reader({
            maxSimultaneousRequests = 40;
            mem = lmem.reader;
            ledger_id;
            start_from_block;
            onError = logErr; // In case a cycle throws an error
            onCycleEnd = func(i : Nat64) { reader_instructions_cost := i }; // returns the instructions the cycle used.
            // It can include multiple calls to onRead
            onRead = func(transactions : [IcrcReader.Transaction], _) {
                icrc_sender.confirm(transactions);

                let ?meta = lmem.meta else Debug.trap("ERR102"); // Not ready yet;
                let fee = meta.fee;
                let ?me = lmem.actor_principal else return;
                label txloop for (tx in transactions.vals()) {
                    if (not Option.isNull(tx.mint)) {
                        let ?mint = tx.mint else continue txloop;
                        if (mint.to.owner == me) {
                            handle_incoming_amount(mint.to.subaccount, mint.amount);

                            ignore do ? {
                                callback_onReceive! (
                                    {
                                        mint with
                                        from = #icrc(getMinter()!); // We can't recieve mint without the ledger having a minter account
                                        spender = null;
                                        fee = null;
                                    } : Transfer
                                );
                            };
                        };
                    };
                    if (not Option.isNull(tx.transfer)) {
                        let ?tr = tx.transfer else continue txloop;

                        if (tr.to.owner == me) {
                            if (tr.amount >= fee) {
                                // ignore it since we can't even burn that
                                handle_incoming_amount(tr.to.subaccount, tr.amount);
                                ignore do ? {
                                    callback_onReceive! ({
                                        tr with
                                        from = #icrc(tr.from);
                                        spender = do ? { #icrc(tr.spender!) };
                                    });
                                };
                            };
                        };

                        if (tr.from.owner == me) {
                            handle_outgoing_amount(tr.from.subaccount, tr.amount + fee);
                        };
                    };
                    if (not Option.isNull(tx.burn)) {
                        let ?burn = tx.burn else continue txloop;
                        if (burn.from.owner == me) {
                            handle_outgoing_amount(burn.from.subaccount, burn.amount + fee);
                        };
                    };
                };
            };
        });

        icrc_sender.setGetReaderLastTxTime(icrc_reader.getReaderLastTxTime);

        /// Set the actor principal. If `start` has been called before, it will really start the ledger.
        public func setOwner(me : Principal) : () {
            lmem.actor_principal := ?me;
        };

        private func refreshFee() : async () {
            try {
                let ?{ fee; decimals; symbol; minter } = lmem.meta else do {
                    logErr("ERR104"); // Internal error - in the strange case when we have this function called but the meta is not set
                    return;
                };
                let ledger = actor (Principal.toText(ledger_id)) : ICRCLedger.Self;
                let newfee = await ledger.icrc1_fee();
                lmem.meta := ?{ decimals; symbol; minter; fee = newfee };
            } catch (e) {};
        };

        // will loop until the actor_principal is set
        private func delayed_start() : async () {
            if (Option.isNull(lmem.meta)) await retrieveMeta();

            if (not Option.isNull(lmem.actor_principal) and not Option.isNull(lmem.meta)) {
                realStart<system>();
                ignore Timer.recurringTimer<system>(#seconds 3600, refreshFee); // every hour

            } else {
                ignore Timer.setTimer<system>(#seconds 3, delayed_start);
            };
        };

        /// Start the ledger timers

        private func retrieveMeta() : async () {
            try {
                let ledger = actor (Principal.toText(ledger_id)) : ICRCLedger.Self;
                let symbol = await ledger.icrc1_symbol();
                let decimals = await ledger.icrc1_decimals();
                let minter = await ledger.icrc1_minting_account();
                let fee = await ledger.icrc1_fee();
                lmem.meta := ?{ symbol; decimals; minter; fee };
            } catch (e) {} // if not cought it will stop the recurring timer
        };

        /// Really starts the ledger and the whole system
        private func realStart<system>() {
            let ?me = lmem.actor_principal else Debug.trap("no actor principal");
            Debug.print(debug_show (me));
            if (started) Debug.trap("already started");
            started := true;
            icrc_sender.start<system>(?me); // We can't call start from the constructor because this is not defined yet
            icrc_reader.start<system>();
        };

        /// Returns the actor principal
        public func me() : Principal {
            let ?me = lmem.actor_principal else Debug.trap("no actor principal");
            me;
        };

        /// Returns the errors that happened
        public func getErrors() : [Text] {
            let start = errors.start();
            Array.tabulate<Text>(
                errors.len(),
                func(i : Nat) {
                    let ?x = errors.getOpt(start + i) else Debug.trap("memory corruption");
                    x;
                },
            );
        };

        /// Returns info about ledger library
        public func getInfo() : Info {
            {
                last_indexed_tx = lmem.reader.last_indexed_tx;
                accounts = Map.size(lmem.accounts);
                pending = icrc_sender.getPendingCount();
                actor_principal = lmem.actor_principal;
                sent = lmem.next_tx_id;
                reader_instructions_cost;
                sender_instructions_cost;
                errors = errors.len();
                lastTxTime = icrc_reader.getReaderLastTxTime();
            };
        };

        /// Get Iter of all accounts owned by the canister (except dust < fee)
        public func accounts() : Iter.Iter<(Blob, Nat)> {
            Iter.map<(Blob, AccountMem), (Blob, Nat)>(Map.entries<Blob, AccountMem>(lmem.accounts), func((k, v)) { (k, v.balance - v.in_transit) });
        };

        /// Returns the fee for sending a transaction
        public func getFee() : Nat {
            let ?m = lmem.meta else Debug.trap("ERR103");
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

        public func genNextSendId() : Nat64 {
            let id = lmem.next_tx_id;
            lmem.next_tx_id += 1;
            id;
        };

        /// Send a transfer from a canister owned address
        /// It's added to a queue and will be sent as soon as possible.
        /// You can send tens of thousands of transactions in one update call. It just adds them to a BTree
        public func send(tr : IcrcSender.TransactionInput) : R<Nat64, SendError> {
            // The amount we send includes the fee. meaning recepient will get the amount - fee
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(tr.from_subaccount)) else return #err(#InsufficientFunds);
            if (acc.balance : Nat - acc.in_transit : Nat < tr.amount) return #err(#InsufficientFunds);
            acc.in_transit += tr.amount;
            let id = lmem.next_tx_id;
            lmem.next_tx_id += 1;
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
        public func onSent(fn : (Nat64) -> ()) : () {
            assert (Option.isNull(callback_onSent));
            callback_onSent := ?fn;
        };

        public func isSent(id : Nat64) : Bool {
            if (id >= lmem.next_tx_id) return false;
            icrc_sender.isSent(id);
        };

        ignore Timer.setTimer<system>(#seconds 0, delayed_start);

    };

};
