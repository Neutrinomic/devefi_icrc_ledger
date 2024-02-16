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

module {
    type R<A,B> = Result.Result<A,B>;

    /// No other errors are currently possible
    type SendError = {
        #InsuficientFunds;
    };

    /// Local account memory
    type AccountMem = {
        var balance: Nat;
        var in_transit: Nat;
    };

    type Mem = {
        reader: IcrcReader.Mem;
        sender: IcrcSender.Mem;
        accounts: Map.Map<Blob, AccountMem>;
        var actor_principal : ?Principal;
        var meta : ?StoredMeta;
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
        }
    };

    private func subaccountToBlob(s: ?Blob) : Blob {
        let ?a = s else return Blob.fromArray([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
        a;
    };


    /// Info about local ledger params returned by getInfo
    public type Info = {
        last_indexed_tx: Nat;
        accounts: Nat;
        pending: Nat;
        actor_principal: ?Principal;
        sender_instructions_cost : Nat64;
        reader_instructions_cost : Nat64;
        errors : Nat;
        lastTxTime: Nat64;
    };

    type StoredMeta = {
        symbol: Text;
        decimals: Nat8;
        minter: ?ICRCLedger.Account;
    };

    public type Meta = StoredMeta and {
        fee: Nat;
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
    public class Ledger(lmem: Mem, ledger_id_txt: Text, start_from_block : ({#id:Nat; #last})) {

        let ledger_id = Principal.fromText(ledger_id_txt);
        var next_tx_id : Nat64 = 0;
        let errors = SWB.SlidingWindowBuffer<Text>();

        var sender_instructions_cost : Nat64 = 0;
        var reader_instructions_cost : Nat64 = 0;

        var callback_onReceive: ?((ICRCLedger.Transfer) -> ()) = null;
        var callback_onSent: ?((ICRCLedger.Transfer) -> ()) = null;
        var callback_onMint: ?((ICRCLedger.Mint) -> ()) = null;
        var callback_onBurn: ?((ICRCLedger.Burn) -> ()) = null;
        // Sender 

        var started : Bool = false;

        private func logErr(e:Text) : () {
            let idx = errors.add(e);
            if ((1+idx) % 300 == 0) { // every 300 elements
                errors.delete( errors.len() - 100 ) // delete all but the last 100
            };
        };

        public func getMinter() : (?ICRCLedger.Account) {
            let ?m = lmem.meta else return null;
            m.minter;
        };

        let icrc_sender = IcrcSender.Sender({
            ledger_id;
            mem = lmem.sender;
            onError = logErr; // In case a cycle throws an error
            onConfirmations = func (confirmations: [Nat64]) {
                // handle confirmed ids after sender - not needed for now
            };
            getMinter = getMinter;
            onCycleEnd = func (i: Nat64) { sender_instructions_cost := i }; // used to measure how much instructions it takes to send transactions in one cycle
        });
        
        public func getMeta() : ?Meta {
            let ?m = lmem.meta else return null;
            let ?fee = icrc_sender.getFee() else return null;
            ?{m with fee};
        };

        private func handle_incoming_amount(subaccount: ?Blob, amount: Nat) : () {
            switch(Map.get<Blob, AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount))) {
                case (?acc) {
                    acc.balance += amount:Nat;
                };
                case (null) {
                    Map.set(lmem.accounts, Map.bhash, subaccountToBlob(subaccount), {
                        var balance = amount;
                        var in_transit = 0;
                    });
                };
            };
        };

        private func handle_outgoing_amount(subaccount: ?Blob, amount: Nat) : () {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return;
            acc.balance -= amount:Nat;

            // When replaying the ledger we don't have in_transit and it results in natural substraction underflow.
            // since in_transit is local and added when sending
            // we have to ignore if it when replaying
            // Also if for some reason devs decide to send funds with something else than this library, it will also be an amount that is not in transit
            if (acc.in_transit < amount) {
                acc.in_transit := 0;
            } else {
                acc.in_transit -= amount:Nat; 
            };

            if (acc.balance == 0 and acc.in_transit == 0) {
                ignore Map.remove<Blob, AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(subaccount));
            };
        };

        // Reader
        let icrc_reader = IcrcReader.Reader({
            mem = lmem.reader;
            ledger_id;
            start_from_block;
            onError = logErr; // In case a cycle throws an error
            onCycleEnd = func (i: Nat64) { reader_instructions_cost := i }; // returns the instructions the cycle used. 
                                                        // It can include multiple calls to onRead
            onRead = func (transactions: [IcrcReader.Transaction]) {
                icrc_sender.confirm(transactions);
                
                let ?fee = icrc_sender.getFee() else return; // Not ready yet;
                let ?me = lmem.actor_principal else return;
                label txloop for (tx in transactions.vals()) {
                    if (not Option.isNull(tx.mint)) {
                        let ?mint = tx.mint else continue txloop;
                        if (mint.to.owner == me) {
                            handle_incoming_amount(mint.to.subaccount, mint.amount);

                            ignore do ? { callback_onMint!(mint); };
                        };
                    };
                    if (not Option.isNull(tx.transfer)) {
                        let ?tr = tx.transfer else continue txloop;
                    
                        if (tr.to.owner == me) {
                            if (tr.amount >= fee) { // ignore it since we can't even burn that
                            handle_incoming_amount(tr.to.subaccount, tr.amount);
                            ignore do ? { callback_onReceive!(tr); };
                            }
                        };

                        if (tr.from.owner == me) {
                            handle_outgoing_amount(tr.from.subaccount, tr.amount + fee);

                            ignore do ? { callback_onSent!(tr); };
                        };
                    };
                    if (not Option.isNull(tx.burn)) {
                        let ?burn = tx.burn else continue txloop;
                        if (burn.from.owner == me) {
                            handle_outgoing_amount(burn.from.subaccount, burn.amount + fee);

                            ignore do ? { callback_onBurn!(burn); };
                        };
                    };
                };
            };
        });

        icrc_sender.setGetReaderLastTxTime(icrc_reader.getReaderLastTxTime);

        /// Set the actor principal. If `start` has been called before, it will really start the ledger.
        public func setOwner(act: actor {}) : () {
            lmem.actor_principal := ?Principal.fromActor(act);
        };

        // will loop until the actor_principal is set
        private func delayed_start() : async () {
          if (Option.isNull(lmem.meta)) await retrieveMeta();

          if (not Option.isNull(lmem.actor_principal) and not Option.isNull(lmem.meta)) {
            realStart();
          } else {
            ignore Timer.setTimer(#seconds 3, delayed_start);
          }
        };

        /// Start the ledger timers
        public func start() : () {
            ignore Timer.setTimer(#seconds 0, delayed_start);
        };

        private func retrieveMeta() : async () {
            try {
            let ledger = actor (Principal.toText(ledger_id)) : ICRCLedger.Self;
            let symbol = await ledger.icrc1_symbol();
            let decimals = await ledger.icrc1_decimals();
            let minter = await ledger.icrc1_minting_account();
            lmem.meta := ?{symbol; decimals; minter};
            } catch (e) {} // if not cought it will stop the recurring timer
        };

        /// Really starts the ledger and the whole system
        private func realStart() {
            let ?me = lmem.actor_principal else Debug.trap("no actor principal");
            Debug.print(debug_show(me));
            if (started) Debug.trap("already started");
            started := true;
            icrc_sender.start(?me); // We can't call start from the constructor because this is not defined yet
            icrc_reader.start();
        };


        /// Returns the actor principal
        public func me() : Principal {
            let ?me = lmem.actor_principal else Debug.trap("no actor principal");
            me;
        };

        /// Returns the errors that happened
        public func getErrors() : [Text] {
            let start = errors.start();
            Array.tabulate<Text>(errors.len(), func (i:Nat) {
                let ?x = errors.getOpt(start + i) else Debug.trap("memory corruption");
                x
            });
        };
    
        /// Returns info about ledger library
        public func getInfo() : Info {
            {
                last_indexed_tx = lmem.reader.last_indexed_tx;
                accounts = Map.size(lmem.accounts);
                pending = icrc_sender.getPendingCount();
                actor_principal = lmem.actor_principal;
                sent = next_tx_id;
                reader_instructions_cost;
                sender_instructions_cost;
                errors = errors.len();
                lastTxTime = icrc_reader.getReaderLastTxTime();
            }
        };

        /// Get Iter of all accounts owned by the canister (except dust < fee)
        public func accounts() : Iter.Iter<(Blob, Nat)> {
            Iter.map<(Blob, AccountMem), (Blob, Nat)>(Map.entries<Blob, AccountMem>(lmem.accounts), func((k, v)) {
                (k, v.balance - v.in_transit)
            });
        };

        /// Returns the fee for sending a transaction
        public func getFee() : ?Nat {
            icrc_sender.getFee();
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
        public func send(tr: IcrcSender.TransactionInput) : R<Nat64, SendError> { // The amount we send includes the fee. meaning recepient will get the amount - fee
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(tr.from_subaccount)) else return #err(#InsuficientFunds);
            if (acc.balance:Nat - acc.in_transit:Nat < tr.amount) return #err(#InsuficientFunds);
            acc.in_transit += tr.amount;
            let id = next_tx_id;
            next_tx_id += 1;
            icrc_sender.send(id, tr);
            #ok(id);
        };

        /// Returns the balance of a subaccount owned by the canister (except dust < fee)
        /// It's different from the balance in the original ledger if sent transactions are not confirmed yet.
        /// We are keeping track of the in_transit amount.
        public func balance(subaccount:?Blob) : Nat {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return 0;
            acc.balance - acc.in_transit;
        };

        /// Called when a received transaction is confirmed. Only one function can be set. (except dust < fee)
        public func onReceive(fn:(ICRCLedger.Transfer) -> ()) : () {
            assert(Option.isNull(callback_onReceive));
            callback_onReceive := ?fn;
        };

        /// Called when a sent transaction is confirmed. Only one function can be set.
        public func onSent(fn:(ICRCLedger.Transfer) -> ()) : () {
            assert(Option.isNull(callback_onSent));
            callback_onSent := ?fn;
        };

        /// Called when a mint transaction is received. Only one function can be set.
        /// In the rare cases when the ledger minter is sending your canister funds you need to handle this.
        /// The event won't show in onRecieve
        public func onMint(fn:(ICRCLedger.Mint) -> ()) : () {
            assert(Option.isNull(callback_onMint));
            callback_onMint := ?fn;
        };

        /// Called when a burn transaction is received. Only one function can be set.
        public func onBurn(fn:(ICRCLedger.Burn) -> ()) : () {
            assert(Option.isNull(callback_onBurn));
            callback_onBurn := ?fn;
        };






    };


}