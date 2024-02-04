import IcrcReader "mo:devefi-icrc-reader";
import IcrcSender "mo:devefi-icrc-sender";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Vector "mo:vector";
import Map "mo:map/Map";
import Blob "mo:base/Blob";
import Result "mo:base/Result";
import Option "mo:base/Option";
import ICRCLedger "./icrc_ledger";

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
        let errors = Vector.new<Text>();
        var callback_onReceive: ?((ICRCLedger.Transfer) -> ()) = null;
        // Sender 

        let icrc_sender = IcrcSender.Sender({
            ledger_id;
            mem = lmem.sender;
            onError = func (e: Text) = Vector.add(errors, e); // In case a cycle throws an error
            onConfirmations = func (confirmations: [Nat64]) {
                // handle confirmed ids
            };
            onCycleEnd = func (instructions: Nat64) {}; // used to measure how much instructions it takes to send transactions in one cycle
        });
        
        // Reader

        let icrc_reader = IcrcReader.Reader({
            mem = lmem.reader;
            ledger_id;
            start_from_block = #last;
            onError = func (e: Text) = Vector.add(errors, e); // In case a cycle throws an error
            onCycleEnd = func (instructions: Nat64) {}; // returns the instructions the cycle used. 
                                                        // It can include multiple calls to onRead
            onRead = func (transactions: [IcrcReader.Transaction]) {
                icrc_sender.confirm(transactions);
                
                let fee = icrc_sender.get_fee();
                let ?me = actor_principal else return;
                label txloop for (tx in transactions.vals()) {
                    let ?tr = tx.transfer else continue txloop;
                    if (tr.to.owner == me) {
                        if (tr.amount <= fee) continue txloop; // ignore it

                        switch(Map.get<Blob, AccountMem>(lmem.accounts, Map.bhash, subaccountToBlob(tr.to.subaccount))) {
                            case (?acc) {
                                acc.balance += tr.amount:Nat;
                            };
                            case (null) {
                                Map.set(lmem.accounts, Map.bhash, subaccountToBlob(tr.to.subaccount), {
                                    var balance = tr.amount;
                                    var in_transit = 0;
                                });
                            };
                        };

                        let ?cb = callback_onReceive else continue txloop;
                        cb(tr);
                    };

                    if (tr.from.owner == me) {
                        let ?acc = Map.get(lmem.accounts, Map.bhash, subaccountToBlob(tr.from.subaccount)) else continue txloop;
                        
                        acc.balance -= tr.amount:Nat;
                        acc.in_transit -= tr.amount:Nat;
                    };
                };
            };
        });

        public func start(act: actor {}) : () {
            let me = Principal.fromActor(act);
            actor_principal := ?me;
            icrc_sender.start(me); // We can't call start from the constructor because this is not defined yet
            icrc_reader.start();
        };

        public func get_errors() : [Text] {
            Vector.toArray(errors)
        };

        public func de_bug() : Text {
            debug_show({
                last_indexed_tx = lmem.reader.last_indexed_tx;
                actor_principal = actor_principal;
            })
        };

        public func send(tr: IcrcSender.TransactionInput) : R<Nat64, SendError> {
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


    }
}