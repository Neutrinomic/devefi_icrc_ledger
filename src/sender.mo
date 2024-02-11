import BTree "mo:stableheapbtreemap/BTree";
import Option "mo:base/Option";
import Debug "mo:base/Debug";
import Nat "mo:base/Nat";
import Float "mo:base/Float";
import Ledger "./icrc_ledger";
import Principal "mo:base/Principal";
import Vector "mo:vector";
import Timer "mo:base/Timer";
import Array "mo:base/Array";
import Error "mo:base/Error";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat32 "mo:base/Nat32";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Prim "mo:⛔";
import Nat8 "mo:base/Nat8";

module {

    let RETRY_EVERY_SEC:Float = 120;
    let MAX_SENT_EACH_CYCLE:Nat = 125;

    public type TransactionInput = {
        amount: Nat;
        to: Ledger.Account;
        from_subaccount : ?Blob;
    };

    public type Transaction = {
        amount: Nat;
        to : Ledger.Account;
        from_subaccount : ?Blob;
        var created_at_time : Nat64; // 1000000000
        memo : Blob;
        var tries: Nat;
    };

    public type Mem = {
        transactions : BTree.BTree<Nat64, Transaction>;
        var stored_owner : ?Principal;
    };

    public func Mem() : Mem {
        return {
            transactions = BTree.init<Nat64, Transaction>(?16);
            var stored_owner = null;
        };
    };

    let permittedDriftNanos : Nat64 = 60_000_000_000;
    let transactionWindowNanos : Nat64 = 86400_000_000_000;
    let retryWindow : Nat64 = 172800_000_000_000; // 2 x transactionWindowNanos
    let allowedLagToChangeWindow : Nat64 = 900_000_000_000; // 15 minutes

    private func adjustTXWINDOW(lastReaderTxTime: Nat64, now:Nat64, time : Nat64) : Nat64 {
        // If tx is still not sent after the transaction window, we need to
        // set its created_at_time to the current window or it will never be sent no matter how much we retry.
        // it has to be set in a way that will still make deduplication work (meaning it can't change during this window)
        // We only try to change the created_at after 2 times the window duration 
        // (giving the reader 2 x TX_WINDOW time to catch up and remove the transaction)
        if (lastReaderTxTime + allowedLagToChangeWindow < now) return time; // Don't change the window if the reader is lagging
        let window_idx = (now - time) / retryWindow;
        return time + (window_idx * retryWindow);
    };

    public class Sender({
        mem : Mem;
        ledger_id: Principal;
        onError: (Text) -> ();
        onConfirmations : ([Nat64]) -> ();
        
        onCycleEnd : (Nat64) -> (); // Measure performance of following and processing transactions. Returns instruction count
    }) {
        var started = false;
        let ledger = actor(Principal.toText(ledger_id)) : Ledger.Oneway;
        let ledger_cb = actor(Principal.toText(ledger_id)) : Ledger.Self;
        var getReaderLastTxTime : ?(() -> (Nat64)) = null;
        var stored_fee:?Nat = null;
        
        var cycle_idx = 0;

        public func setGetReaderLastTxTime(fn : () -> (Nat64)) {
            getReaderLastTxTime := ?fn;
        };

        private func cycle() : async () {
            let ?owner = mem.stored_owner else return;
            if (not started) return;
            cycle_idx += 1;
            let inst_start = Prim.performanceCounter(1); // 1 is preserving with async

            if (Option.isNull(stored_fee) or (cycle_idx % 600 == 0)) { // We could also use last observed by reader fee, but I am not sure that's part of the spec (perhaps someone is allowed to pay higher than the minimum fee)
                stored_fee := ?(await ledger_cb.icrc1_fee());
                };
            let ?fee = stored_fee else Debug.trap("Fee not available");

            let now = Int.abs(Time.now());
            let nowU64 = Nat64.fromNat(now);

            let transactions_to_send = BTree.scanLimit<Nat64, Transaction>(mem.transactions, Nat64.compare, 0, ^0, #fwd, 3000);

            let ?gr_fn = getReaderLastTxTime else Debug.trap("Err getReaderLastTxTime not set");
            let lastReaderTxTime = gr_fn();  // This is the last time the reader has seen a transaction or the current time if there are no more transactions


            var sent_count = 0;
            label vtransactions for ((id, tx) in transactions_to_send.results.vals()) {
                
                if (tx.amount <= fee) {
                    ignore BTree.delete<Nat64, Transaction>(mem.transactions, Nat64.compare, id);
                    continue vtransactions;
                };

                let time_for_try = Float.toInt(Float.ceil((Float.fromInt(now - Nat64.toNat(tx.created_at_time)))/RETRY_EVERY_SEC));

                if (tx.tries >= time_for_try) continue vtransactions;
                
                let created_at_adjusted = adjustTXWINDOW(lastReaderTxTime, nowU64, tx.created_at_time);
                if ((created_at_adjusted < nowU64) and (nowU64 - created_at_adjusted > transactionWindowNanos + permittedDriftNanos)) continue vtransactions; // Too OLD

                try {
                    // Relies on transaction deduplication https://github.com/dfinity/ICRC-1/blob/main/standards/ICRC-1/README.md
                    ledger.icrc1_transfer({
                        amount = tx.amount - fee;
                        to = tx.to;
                        from_subaccount = tx.from_subaccount;
                        created_at_time = ?created_at_adjusted;
                        memo = ?tx.memo;
                        fee = ?fee;
                    });
                    sent_count += 1;
                    tx.tries += 1;
                } catch (e) { 
                    onError("sender:" # Error.message(e));
                    break vtransactions;
                };

                if (sent_count >= MAX_SENT_EACH_CYCLE) break vtransactions;
    
            };
    
            ignore Timer.setTimer(#seconds 2, cycle);
            let inst_end = Prim.performanceCounter(1);
            onCycleEnd(inst_end - inst_start);
        };



        public func confirm(txs: [Ledger.Transaction]) {
            let ?owner = mem.stored_owner else return;

            let confirmations = Vector.new<Nat64>();
            label tloop for (tx in txs.vals()) {
                let ?tr = tx.transfer else continue tloop;
                if (tr.from.owner != owner) continue tloop;
                let ?memo = tr.memo else continue tloop;
                let ?id = DNat64(Blob.toArray(memo)) else continue tloop;
                
                ignore BTree.delete<Nat64, Transaction>(mem.transactions, Nat64.compare, id);
                Vector.add<Nat64>(confirmations, id);
            };
            onConfirmations(Vector.toArray(confirmations));
        };

        public func getFee() : Nat {
            let ?fee = stored_fee else Debug.trap("Fee not available");
            return fee;
        };

        public func getPendingCount() : Nat {
            return BTree.size(mem.transactions);
        };

        public func send(id:Nat64, tx: TransactionInput) {
            let txr : Transaction = {
                amount = tx.amount;
                to = tx.to;
                from_subaccount = tx.from_subaccount;
                var created_at_time = Nat64.fromNat(Int.abs(Time.now()));
                memo = Blob.fromArray(ENat64(id));
                var tries = 0;
            };
            
            ignore BTree.insert<Nat64, Transaction>(mem.transactions, Nat64.compare, id, txr);
        };

        public func start(owner:?Principal) {
            if (not Option.isNull(owner)) mem.stored_owner := owner;
            if (Option.isNull(mem.stored_owner)) return;

            if (started) Debug.trap("already started");
            started := true;
            ignore Timer.setTimer(#seconds 2, cycle);
        };

        public func stop() {
            started := false;
        };

        public func ENat64(value : Nat64) : [Nat8] {
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

        public func DNat64(array : [Nat8]) : ?Nat64 {
            if (array.size() != 8) return null;
            return ?(Nat64.fromNat(Nat8.toNat(array[0])) << 56 | Nat64.fromNat(Nat8.toNat(array[1])) << 48 | Nat64.fromNat(Nat8.toNat(array[2])) << 40 | Nat64.fromNat(Nat8.toNat(array[3])) << 32 | Nat64.fromNat(Nat8.toNat(array[4])) << 24 | Nat64.fromNat(Nat8.toNat(array[5])) << 16 | Nat64.fromNat(Nat8.toNat(array[6])) << 8 | Nat64.fromNat(Nat8.toNat(array[7])));
        };
    };

};
