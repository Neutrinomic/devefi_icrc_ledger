import L "../../src/icrc_ledger";
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
import Error "mo:base/Error";

actor class ({ ledgerId : Principal }) = this {

    type R<A,B> = Result.Result<A,B>;
    var calledCount = 0;
    private func test_subaccount(n : Nat64) : ?Blob {
        ?Blob.fromArray(Iter.toArray(I.pad<Nat8>(Iter.fromArray(ENat64(n)), 32, 0 : Nat8)));
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

    var next_subaccount_id : Nat64 = 100000;

    public query ({caller}) func whoami() : async Text {
        return Principal.toText(caller);
    };

    public shared ({ caller }) func pay() : async R<(), Text> {
        calledCount += 1;
        let reciever : L.Account = {
            owner = Principal.fromActor(this);
            subaccount = null;
        };
        let amount = 1_0000_0000;
        let ledger = actor (Principal.toText(ledgerId)) : L.Self;
        try {
            switch (await ledger.icrc2_transfer_from({ from = { owner = caller; subaccount = null }; spender_subaccount = null; to = reciever; fee = null; memo = null; from_subaccount = null; created_at_time = null; amount = amount })) {
                case (#Ok(_)) #ok();
                case (#Err(e)) #err("Ledger err " # debug_show(e));
            };
        } catch (e) {
            #err("Trap : "#Error.message(e));
        }
    };

    public query func get_called_count() : async Nat {
        return calledCount;
    };

};
