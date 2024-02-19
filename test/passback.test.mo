import L "../src";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import I "mo:itertools/Iter";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Debug "mo:base/Debug";


actor class({ledgerId: Principal}) = this {

    stable let lmem = L.LMem();
    let ledger = L.Ledger(lmem, Principal.toText(ledgerId), #last);
    
    ledger.onReceive(func (t) {
        ignore ledger.send({ to = t.from; amount = t.amount; from_subaccount = t.to.subaccount; });
    });

    
    ledger.start();
    //---

    public func start() {
        ledger.setOwner(this);
        };

    public query func get_balance(s: ?Blob) : async Nat {
        ledger.balance(s)
        };

    public query func get_errors() : async [Text] {
        ledger.getErrors();
        };

    public query func get_info() : async L.Info {
        ledger.getInfo();
        };

    public query func accounts() : async [(Blob, Nat)] {
        Iter.toArray(ledger.accounts());
        };

    public query func getPending() : async Nat {
        ledger.getSender().getPendingCount();
        };
    
    public query func ver() : async Nat {
        4
        };
    
    public query func getMeta() : async L.Meta {
        ledger.getMeta()
        };
}