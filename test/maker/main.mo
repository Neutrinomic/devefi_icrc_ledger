import L "../../src";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import I "mo:itertools/Iter";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Debug "mo:base/Debug";

actor class() = this {


    private func test_subaccount(n:Nat64) : ?Blob {
        ?Blob.fromArray(Iter.toArray(I.pad<Nat8>( Iter.fromArray(ENat64(n)), 32, 0 : Nat8)));
    };

    private func ENat64(value : Nat64) : [Nat8] {
        return [
            Nat8.fromNat(Nat64.toNat(value >> 56)),
            Nat8.fromNat(Nat64.toNat((value >> 48) & 255)),
            Nat8.fromNat(Nat64.toNat((value >> 40) & 255)),
            Nat8.fromNat(Nat64.toNat((value >> 32) & 255)),
            Nat8.fromNat(Nat64.toNat((value >> 24) & 255)),
            Nat8.fromNat(Nat64.toNat((value >> 16) & 255)),
            Nat8.fromNat(Nat64.toNat((value >> 8) & 255)),
            Nat8.fromNat(Nat64.toNat(value & 255)),
        ];
    };

    let fee = 10_000; //TODO: Put getFee func inside library

    var next_subaccount_id:Nat64 = 100000;

    stable let lmem = L.LMem();
    let ledger = L.Ledger(lmem, "bnz7o-iuaaa-aaaaa-qaaaa-cai", #last);
    
    ledger.onMint(func (t) {
       // if sent mint transaction to this canister
       // we will split into 10,000 subaccounts
        var i = 0;
        label sending loop {
            let amount = Int.abs(Float.toInt( Float.fromInt(t.amount) * 0.00005 )); // each acount gets 1/10000 of the amount
            ignore ledger.send({ to = {owner=ledger.me(); subaccount=test_subaccount(Nat64.fromNat(i))}; amount; from_subaccount = t.to.subaccount; });
            i += 1;
            if (i >= 10_000) break sending;
        }
    });

    let dust = 10000; // leave dust to try the balance of function

    ledger.onReceive(func (t) {
        // if it has subaccount
        // we will pass it to another subaccount
        // until there is nothing to pass left the amount recieved is 0
        if (t.amount < fee + dust) return;
        ignore ledger.send({ to = {owner=ledger.me(); subaccount=test_subaccount(next_subaccount_id)}; amount = t.amount - dust; from_subaccount = t.to.subaccount; });
        next_subaccount_id += 1;
    });
    
    ledger.start();
    //---

    public func start() {
        Debug.print("started");
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
     }
    
}