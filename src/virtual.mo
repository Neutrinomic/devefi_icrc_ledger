import L "./lib";
import Map "mo:map/Map";
import Blob "mo:base/Blob";
import IcrcSender "./sender";
import Result "mo:base/Result";
import ICRCLedger "./icrc_ledger";
import Option "mo:base/Option";
import Iter "mo:base/Iter";

module {
    type R<A, B> = Result.Result<A, B>;

    public type SendError = {
        #InsufficientFunds;
    };

    public type AccountMem = {
        var balance : Nat;
    };

    public type Mem = {
        accounts : Map.Map<Blob, AccountMem>;
        var collected_fees : Nat;
    };

    public func Mem() : Mem {
        {
            accounts = Map.new<Blob, AccountMem>();
            var collected_fees = 0;
        };
    };

    public type TransferRecieved = {
        amount : Nat;
        to_subaccount : ?Blob;
    };

    public type AccountMixed = {
        #icrc : ICRCLedger.Account;
        #icp : Blob;
    };

    public type Transfer = {
        to : ICRCLedger.Account;
        fee : ?Nat;
        from : AccountMixed;
        memo : ?Blob;
        created_at_time : ?Nat64;
        amount : Nat;
        spender : ?AccountMixed;
    };

    // We need to make it work for ICP and ICRC
    public type ExpectedLedger = {
        accounts : () -> Iter.Iter<(Blob, Nat)>;
        balance : ?Blob -> Nat;
        genNextSendId : () -> Nat64;
        getErrors : () -> [Text];
        getFee : () -> Nat;
        isSent : Nat64 -> Bool;
        me : () -> Principal;
        onReceive : (L.Transfer -> ()) -> ();
        onSent : (Nat64 -> ()) -> ();
        send : IcrcSender.TransactionInput -> R<Nat64, L.SendError>;
        setOwner : Principal -> ()
    };

    public class Virtual<system>(mem : Mem, ledger: ExpectedLedger) {

        var callback_onReceive : ?((TransferRecieved) -> ()) = null;
        var callback_onSent : ?((Nat64) -> ()) = null;
        var callback_onRecieveShouldVirtualize : ?((Transfer) -> Bool) = null;

        public func onReceive(fn:(TransferRecieved) -> ()) : () {
            assert(Option.isNull(callback_onReceive));
            callback_onReceive := ?fn;
        };

        public func onSent(fn:(Nat64) -> ()) : () {
            assert(Option.isNull(callback_onSent));
            callback_onSent := ?fn;
        };

        public func onRecieveShouldVirtualize(fn:(Transfer) -> Bool) : () {
            assert(Option.isNull(callback_onRecieveShouldVirtualize));
            callback_onRecieveShouldVirtualize := ?fn;
        };

        public func registerSubaccount(_subaccount: ?Blob) : () {
            // Only used in the ICP version
        };

        public func unregisterSubaccount(_subaccount: ?Blob) : () {
            // Only used in the ICP version
        };

        /// Virtual balance
        public func balance(subaccount : ?Blob) : Nat {
            let ?acc = Map.get(mem.accounts, Map.bhash, L.subaccountToBlob(subaccount)) else return 0;
            acc.balance;
        };

        /// Send from virtual address
        public func send(tr : IcrcSender.TransactionInput) : R<Nat64, SendError> {
            // The amount we send includes the fee. meaning recepient will get the amount - fee
            let ?acc = Map.get(mem.accounts, Map.bhash, L.subaccountToBlob(tr.from_subaccount)) else return #err(#InsufficientFunds);
            if (acc.balance : Nat < tr.amount) return #err(#InsufficientFunds);

            let fee = ledger.getFee();
            if (tr.amount < fee) return #err(#InsufficientFunds);

            let id = ledger.genNextSendId();

            let { amount; to; from_subaccount } = tr;
            // If local just move the tokens in pooled ledger
            if (to.owner == ledger.me()) {
                handle_outgoing_amount(from_subaccount, amount);
                handle_incoming_amount(to.subaccount, amount - fee);
                mem.collected_fees += fee;
                ignore do ? { // This will cause recursion if onRecieve sends (as intended) so be careful with it
                    callback_onReceive!({
                        amount = amount - fee;
                        to_subaccount = to.subaccount;
                    });
                };
                #ok(id);
            } else {
                let #ok(id) = ledger.send({
                    from_subaccount = null; // pool account
                    to = to;
                    amount = amount;
                }) else return(#err(#InsufficientFunds));
                
                handle_outgoing_amount(from_subaccount, amount);
                // If remote, send tokens from pool to remote account
                #ok(id);
            };
        };

        private func handle_incoming_amount(subaccount : ?Blob, amount : Nat) : () {
            switch (Map.get<Blob, AccountMem>(mem.accounts, Map.bhash, L.subaccountToBlob(subaccount))) {
                case (?acc) {
                    acc.balance += amount : Nat;
                };
                case (null) {
                    Map.set(
                        mem.accounts,
                        Map.bhash,
                        L.subaccountToBlob(subaccount),
                        {
                            var balance = amount;
                            var in_transit = 0;
                        },
                    );
                };
            };
        };

        private func handle_outgoing_amount(subaccount : ?Blob, amount : Nat) : () {
            let ?acc = Map.get(mem.accounts, Map.bhash, L.subaccountToBlob(subaccount)) else return;
            acc.balance -= amount : Nat;

            if (acc.balance == 0) {
                ignore Map.remove<Blob, AccountMem>(mem.accounts, Map.bhash, L.subaccountToBlob(subaccount));
            };

        };

        /// Get Iter of all accounts owned by the canister (except dust < fee)
        public func accounts() : Iter.Iter<(Blob, Nat)> {
            Iter.map<(Blob, AccountMem), (Blob, Nat)>(Map.entries<Blob, AccountMem>(mem.accounts), func((k, v)) { (k, v.balance) });
        };


        ledger.onReceive(
            func(tx) {
                
                // If we are sending from a subaccount to the pool it will always have from = #icrc and not #icp
                switch(tx.from) {
                    case (#icrc(from)) {
                        if (from.owner == ledger.me() and from.subaccount != null and tx.to.subaccount == null) {
                            // a subaccount is sending tokens to the pool
                            handle_incoming_amount(from.subaccount, tx.amount);
                            ignore do ? {
                                callback_onReceive!({
                                    amount = tx.amount;
                                    to_subaccount = from.subaccount;
                                });
                            };
                            return;
                        } else {
                            if (from.owner != ledger.me() and tx.to.subaccount == null) {
                                // Someone from outside is sending to the pool
                                handle_incoming_amount(tx.to.subaccount, tx.amount);
                                ignore do ? {
                                    callback_onReceive!({
                                        amount = tx.amount;
                                        to_subaccount = null;
                                    });
                                };
                                return;
                            }
                        } 
                    };
                    case (#icp(_)) ();
                };

                // External transfer to a subaccount
                let pass = do ? { callback_onRecieveShouldVirtualize!(tx); };
                if (Option.isNull(pass) or pass == ?true) {
                    ignore ledger.send({
                        from_subaccount = tx.to.subaccount; 
                        to = {
                            owner = ledger.me();
                            subaccount = null; // pool account
                            };
                        amount = tx.amount;
                        });
                }
               
            }
        );

    };

};
