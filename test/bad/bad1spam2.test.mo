import L "../src/icrc_ledger";
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
import Bool "mo:base/Bool";

actor class ({ userCanId : Principal }) = this {

    var stopped : Bool = true;
    var lidx = 0;
    system func heartbeat() : async () {
        if (stopped) return;
        if (lidx > 400) return;
        let testcan = actor(Principal.toText(userCanId)) : actor {
                pay : shared () -> ();
        };
        lidx += 1;
        label loo loop {
            // try {
            testcan.pay();
            // } catch (e) {
            //     break loo;
            // };
        };
        
    };

    public shared func start() : async () {
        stopped := false;
        lidx := 0;
    };

    public shared func stop() : async () {
        stopped := true;
    }
};
