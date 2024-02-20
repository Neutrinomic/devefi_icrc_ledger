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
    var errors = 0;
    var lidx = 0;
    var errTxt : Text = "";
    system func heartbeat() : async () {
        if (stopped) return;
   
        let testcan = actor(Principal.toText(userCanId)) : actor {
                pay : shared () -> async {#ok; #err:Text};
        };

        lidx += 1;
        label loo loop {
            let rez = await testcan.pay();
            switch(rez) {
                case (#err(e)) {
                    errors += 1;
                    errTxt := errTxt # "|" # debug_show(e);
                };
                case (#ok) {
                    ()
                };
            };
        };
        
    };
    
    public query func get_errors() : async (Nat, Nat, Text) {
        return (errors, lidx, errTxt);
    };

    public shared func start() : async () {
        stopped := false;
        lidx := 0;
    };

    public shared func stop() : async () {
        stopped := true;
    }
};
