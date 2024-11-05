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
    };

    public func Mem() : Mem {
        return {
            transactions = BTree.init<Nat64, Transaction>(?16);
        };
    };
    let MAX_SENT_EACH_CYCLE:Nat = 90;

    let RETRY_EVERY_SEC:Float = 120_000_000_000; // 2 minutes

    let permittedDriftNanos : Nat64 = 60_000_000_000;
    let transactionWindowNanos : Nat64 = 86400_000_000_000;
    let retryWindow : Nat64 = 72200_000_000_000;
    let maxReaderLag : Nat64 = 1800_000_000_000; // 30 minutes
    private func adjustTXWINDOW(now:Nat64, time : Nat64) : Nat64 {
        // If tx is still not sent after the transaction window, we need to
        // set its created_at_time to the current window or it will never be sent no matter how much we retry.
        if (time >= now - retryWindow) return time;
        let window_idx = now / retryWindow;
        return window_idx * retryWindow;
    };

    public class Sender<system>({
        mem : Mem;
        ledger_id: Principal;
        onError: (Text) -> ();
        onConfirmations : ([Nat64]) -> ();
        getFee : () -> Nat;
        getMinter : () -> (?Ledger.Account);
        onCycleEnd : (Nat64) -> (); // Measure performance of following and processing transactions. Returns instruction count
        me_can : Principal;
    }) {
        let ledger = actor(Principal.toText(ledger_id)) : Ledger.Oneway;
        var getReaderLastTxTime : ?(() -> (Nat64)) = null;
        

        public func setGetReaderLastTxTime(fn : () -> (Nat64)) {
            getReaderLastTxTime := ?fn;
        };

        public func isSent(id:Nat64) : Bool {
            not BTree.has(mem.transactions, Nat64.compare, id);
        };

        private func cycle<system>() : async () {
            let inst_start = Prim.performanceCounter(1); // 1 is preserving with async

            let fee = getFee();

            let now = Int.abs(Time.now());
            let nowU64 = Nat64.fromNat(now);

            let transactions_to_send = BTree.scanLimit<Nat64, Transaction>(mem.transactions, Nat64.compare, 0, ^0, #fwd, 3000);

            let ?gr_fn = getReaderLastTxTime else Debug.trap("Err getReaderLastTxTime not set");
            let lastReaderTxTime = gr_fn();  // This is the last time the reader has seen a transaction or the current time if there are no more transactions

            if (lastReaderTxTime != 0 and lastReaderTxTime < nowU64 - maxReaderLag) {
                onError("Reader is lagging behind by " # Nat64.toText(nowU64 - lastReaderTxTime));
                return; // Don't attempt to send transactions if the reader is lagging too far behind
            };
            var sent_count = 0;
            label vtransactions for ((id, tx) in transactions_to_send.results.vals()) {
                if (tx.amount < fee) {
                    ignore BTree.delete<Nat64, Transaction>(mem.transactions, Nat64.compare, id);
                    continue vtransactions;
                };

                let time_for_try = Float.toInt(Float.ceil((Float.fromInt(now - Nat64.toNat(tx.created_at_time)))/RETRY_EVERY_SEC));

                if (tx.tries >= time_for_try) continue vtransactions;
                
                let created_at_adjusted = adjustTXWINDOW(nowU64, tx.created_at_time);

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
                    tx.tries := Int.abs(time_for_try);
                } catch (e) { 
                    onError("sender:" # Error.message(e));
                    break vtransactions;
                };

                if (sent_count >= MAX_SENT_EACH_CYCLE) break vtransactions;
    
            };
    
            let inst_end = Prim.performanceCounter(1);
            onCycleEnd(inst_end - inst_start);
        };


        private func getTxMemoFrom(tx: Ledger.Transaction) : ?(Ledger.Account, Blob) {
            if (tx.kind == "mint") {
                let ?mint = tx.mint else return null;
                let ?memo = mint.memo else return null;
                let ?minter = getMinter() else return null;
                return ?(minter, memo);
            };
            if (tx.kind == "transfer") {
                let ?tr = tx.transfer else return null;
                let ?memo = tr.memo else return null;
                return ?(tr.from, memo);
            };
            if (tx.kind == "burn") {
                let ?burn = tx.burn else return null;
                let ?memo = burn.memo else return null;
                return ?(burn.from, memo);
            };
            null;
        };

        public func confirm(txs: [Ledger.Transaction]) {
            // If our canister sends to a burn address it will be a burn tx.
            // If our canister is the minter address, tx will appear as mint
            // otherwise they will be transfer txs
            // All need to be confirmed

            let confirmations = Vector.new<Nat64>();
            label tloop for (tx in txs.vals()) { 
                
                let ?(tx_from, tx_memo) = getTxMemoFrom(tx) else continue tloop;
                if (tx_from.owner != me_can) continue tloop;
                let ?id = DNat64(Blob.toArray(tx_memo)) else continue tloop;
                
                ignore BTree.delete<Nat64, Transaction>(mem.transactions, Nat64.compare, id);
                Vector.add<Nat64>(confirmations, id);
            };
            onConfirmations(Vector.toArray(confirmations));
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

        ignore Timer.recurringTimer<system>(#seconds 2, cycle);
    };

};
