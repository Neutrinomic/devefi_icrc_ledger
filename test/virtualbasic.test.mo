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
import Virtual "../src/virtual";


actor class({ledgerId: Principal}) = this {


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


    var next_subaccount_id:Nat64 = 100000;

    stable let lmem = L.LMem();
    let ledger = L.Ledger<system>(lmem, Principal.toText(ledgerId), #last);
    
    let virtual_mem = Virtual.Mem();
    let virtual = Virtual.Virtual<system>(virtual_mem, ledger);


    virtual.onReceive(func (t) {

        if (t.to_subaccount == null) {
            // we will split into 1,000 subaccounts
            var i = 0;
            label sending loop {
                let amount = t.amount / 10000; // Each account gets 1/10000
                ignore virtual.send({ to = {owner=ledger.me(); subaccount=test_subaccount(Nat64.fromNat(i))}; amount; from_subaccount = t.to_subaccount; });
                i += 1;
                if (i >= 1_000) break sending;
            }
        } else {
            // if it has subaccount
            // we will pass half to another subaccount
            if (t.amount/10 < ledger.getFee() ) return; // if we send that it will be removed from our balance but won't register
            let subaccount_id = next_subaccount_id;
            next_subaccount_id += 1;
            ignore virtual.send({ to = {owner=ledger.me(); subaccount=test_subaccount(subaccount_id)}; amount = t.amount / 10 ; from_subaccount = t.to_subaccount; });
            
        }
    });
    
    //---

    public func start() {
        Debug.print("started");
        ledger.setOwner(Principal.fromActor(this));
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
        Iter.toArray(virtual.accounts());
        };

    public query func ledger_accounts() : async [(Blob, Nat)] {
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