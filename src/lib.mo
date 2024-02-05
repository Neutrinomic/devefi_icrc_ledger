import IcrcReader "mo:devefi-icrc-reader";
import IcrcSender "mo:devefi-icrc-sender";
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

module {
    type R<A,B> = Result.Result<A,B>;

    type SendError = {
        #InsuficientFunds;
    };

    type AccountMem = {
        var balance: Nat;
        var in_transit: Nat;
    };

    type Mem = {
        reader: IcrcReader.Mem;
        sender: IcrcSender.Mem;
        accounts: Map.Map<Blob, AccountMem>;
    };

    public func LMem() : Mem {
        {
            reader = IcrcReader.Mem();
            sender = IcrcSender.Mem();
            accounts = Map.new<Blob, AccountMem>();
        }
    };

    private func subaccountToBlob(s: ?Blob) : Blob {
        let ?a = s else return Blob.fromArray([]);
        a;
    };

    public class Ledger(lmem: Mem, ledger_id_txt: Text) {
        let ledger_id = Principal.fromText(ledger_id_txt);
        var actor_principal : ?Principal = null;
        var next_tx_id : Nat64 = 0;
        let errors = SWB.SlidingWindowBuffer<Text>();

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

        let icrc_sender = IcrcSender.Sender({
            ledger_id;
            mem = lmem.sender;
            onError = logErr; // In case a cycle throws an error
            onConfirmations = func (confirmations: [Nat64]) {
                // handle confirmed ids
            };
            onCycleEnd = func (instructions: Nat64) {}; // used to measure how much instructions it takes to send transactions in one cycle
        });
        

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
            acc.in_transit -= amount:Nat;
        };

        // Reader
        let icrc_reader = IcrcReader.Reader({
            mem = lmem.reader;
            ledger_id;
            start_from_block = #last;
            onError = logErr; // In case a cycle throws an error
            onCycleEnd = func (instructions: Nat64) {}; // returns the instructions the cycle used. 
                                                        // It can include multiple calls to onRead
            onRead = func (transactions: [IcrcReader.Transaction]) {
                icrc_sender.confirm(transactions);
                
                let fee = icrc_sender.getFee();
                let ?me = actor_principal else return;
                label txloop for (tx in transactions.vals()) {
                    
                    if (not Option.isNull(tx.mint)) {
                        let ?mint = tx.mint else continue txloop;
                        if (mint.to.owner == me) {
                            handle_incoming_amount(mint.to.subaccount, mint.amount);

                            let ?cb = callback_onMint else continue txloop;
                            cb(mint);
                        };
                        
                    };
                    if (not Option.isNull(tx.transfer)) {
                        let ?tr = tx.transfer else continue txloop;
                    
                        if (tr.to.owner == me) {
                            if (tr.amount < fee) continue txloop; // ignore it since we can't even burn that

                            handle_incoming_amount(tr.to.subaccount, tr.amount);

                            let ?cb = callback_onReceive else continue txloop;
                            cb(tr);
                        };

                        if (tr.from.owner == me) {
                            handle_outgoing_amount(tr.from.subaccount, tr.amount + fee);
                            let ?cb = callback_onSent else continue txloop;
                            cb(tr);
                        };
                    };
                    if (not Option.isNull(tx.burn)) {
                        let ?burn = tx.burn else continue txloop;
                        if (burn.from.owner == me) {
                            handle_outgoing_amount(burn.from.subaccount, burn.amount + fee);
                            let ?cb = callback_onBurn else continue txloop;
                            cb(burn);
                        };
                    };
                };
            };
        });

        public func setOwner(act: actor {}) : () {
            actor_principal := ?Principal.fromActor(act);
        };

        // will loop until the actor_principal is set
        private func delayed_start() : async () {
          if (not Option.isNull(actor_principal)) {
            realStart();
          } else {
            ignore Timer.setTimer(#seconds 3, delayed_start);
          }
        };

        public func start() : () {
          ignore Timer.setTimer(#seconds 0, delayed_start);
        };
 
        private func realStart() {
            let ?me = actor_principal else Debug.trap("no actor principal");
            Debug.print(debug_show(me));
            if (started) Debug.trap("already started");
            started := true;
            icrc_sender.start(?me); // We can't call start from the constructor because this is not defined yet
            icrc_reader.start();
        };

        public func getErrors() : [Text] {
            let start = errors.start();
            Array.tabulate<Text>(errors.len(), func (i:Nat) {
                let ?x = errors.getOpt(start + i) else Debug.trap("memory corruption");
                x
            });
        };
    
        public func de_bug() : Text {
            debug_show({
                last_indexed_tx = lmem.reader.last_indexed_tx;
                actor_principal = actor_principal;
            })
        };

        public func getFee() : Nat {
            icrc_sender.getFee();
        };

        public func getSender() : IcrcSender.Sender {
            icrc_sender;
        };

        public func getReader() : IcrcReader.Reader {
            icrc_reader;
        };

        public func send(tr: IcrcSender.TransactionInput) : R<Nat64, SendError> { // The amount we send includes the fee. meaning recepient will get the amount - fee
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(tr.from_subaccount)) else return #err(#InsuficientFunds);
            if (acc.balance:Nat - acc.in_transit:Nat < tr.amount) return #err(#InsuficientFunds);
            acc.in_transit += tr.amount;
            let id = next_tx_id;
            next_tx_id += 1;
            icrc_sender.send(id, tr);
            #ok(id);
        };

        public func balance(subaccount:?Blob) : Nat {
            let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(subaccount)) else return 0;
            acc.balance - acc.in_transit;
        };

        public func onReceive(fn:(ICRCLedger.Transfer) -> ()) : () {
            callback_onReceive := ?fn;
        };

        public func onSent(fn:(ICRCLedger.Transfer) -> ()) : () {
            callback_onSent := ?fn;
        };

        public func onMint(fn:(ICRCLedger.Mint) -> ()) : () {
            callback_onMint := ?fn;
        };

        public func onBurn(fn:(ICRCLedger.Burn) -> ()) : () {
            callback_onBurn := ?fn;
        };
    }
}