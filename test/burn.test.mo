import L "../src";
import LC "../src/icrc_ledger";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import I "mo:itertools/Iter";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Debug "mo:base/Debug";
import Result "mo:base/Result";

actor class({ledgerId: Principal}) = this {

    type R<A,B> = Result.Result<A,B>;


    stable let lmem = L.Mem.Ledger.V1.new();
    let ledger = L.Ledger<system>(lmem, Principal.toText(ledgerId), #last, Principal.fromActor(this));


    public shared func send_to(to: LC.Account, amount: Nat) : async R<Nat64, L.SendError> {
        ledger.send({ to = to; amount; from_subaccount = null; });
    };
    //---

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
    
    public query func getMeta() : async L.Mem.Ledger.V1.Meta {
        ledger.getMeta()
        };
}