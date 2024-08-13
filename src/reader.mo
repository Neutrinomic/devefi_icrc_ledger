import Ledger "./icrc_ledger";
import Principal "mo:base/Principal";
import Error "mo:base/Error";
import Timer "mo:base/Timer";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Vector "mo:vector";
import Debug "mo:base/Debug";
import Prim "mo:⛔";
import Nat64 "mo:base/Nat64";
import Time "mo:base/Time";
import Int "mo:base/Int";
import List "mo:base/List";

module {
    public type Transaction = Ledger.Transaction;

    public type Mem = {
            var last_indexed_tx : Nat;
        };

    type TransactionUnordered = {
            start : Nat;
            transactions : [Ledger.Transaction];
        };
        
    public func Mem() : Mem {
            return {
                var last_indexed_tx = 0;
            };
        };

    public class Reader({
        mem : Mem;
        ledger_id : Principal;
        start_from_block: {#id:Nat; #last};
        onError : (Text) -> (); // If error occurs during following and processing it will return the error
        onCycleEnd : (Nat64) -> (); // Measure performance of following and processing transactions. Returns instruction count
        onRead : ([Ledger.Transaction], Nat) -> ();
    }) {
        var started = false;
        let ledger = actor (Principal.toText(ledger_id)) : Ledger.Self;
        var lastTxTime : Nat64 = 0;

        private func cycle() : async Bool {
            if (not started) return false;
            let inst_start = Prim.performanceCounter(1); // 1 is preserving with async

            if (mem.last_indexed_tx == 0) {
                switch(start_from_block) {
                    case (#id(id)) {
                        mem.last_indexed_tx := id;
                    };
                    case (#last) {
                        let rez = await ledger.get_transactions({
                            start = 0;
                            length = 0;
                        });
                        mem.last_indexed_tx := rez.log_length -1;
                    };
                };
            };

            let rez = await ledger.get_transactions({
                start = mem.last_indexed_tx;
                length = 2000 * 40;
            });
            let quick_cycle:Bool = if (rez.log_length > mem.last_indexed_tx + 1000) true else false;

            if (rez.archived_transactions.size() == 0) {
                // We can just process the transactions that are inside the ledger and not inside archive
                onRead(rez.transactions, mem.last_indexed_tx);
                mem.last_indexed_tx += rez.transactions.size();
         
                if (rez.transactions.size() != 0) lastTxTime := rez.transactions[rez.transactions.size() - 1].timestamp;
            
            } else {
                // We need to collect transactions from archive and get them in order
                let unordered = Vector.new<TransactionUnordered>(); // Probably a better idea would be to use a large enough var array
                // onError("working on archived blocks");

                for (atx in rez.archived_transactions.vals()) {
                    let args_starts = Array.tabulate<Nat>(Nat.min(40, 1 + atx.length/2000), func(i) = atx.start + i*2000);
                    let args = Array.map<Nat, Ledger.GetBlocksRequest>( args_starts, func(i) = {start = i; length = if (i - atx.start:Nat+2000 <= atx.length) 2000 else atx.length + atx.start - i } );

                    // onError("args_starts: " # debug_show(args));


                    var buf = List.nil<async Ledger.TransactionRange>();
                    var data = List.nil<Ledger.TransactionRange>();
                    for (arg in args.vals()) {
                        // The calls are sent here without awaiting anything
                        let promise = atx.callback(arg);
                        buf := List.push(promise, buf); 
                    };

                    for (promise in List.toIter(buf)) {
                        // Await results of all promises. We recieve them in sequential order
                        data := List.push(await promise, data);
                    };
                    let chunks = List.toArray(data);
                    
                    var chunk_idx = 0;
                    for (chunk in chunks.vals()) {
                        if (chunk.transactions.size() > 0) {
                            // If chunks (except the last one) are smaller than 2000 tx then implementation is strange
                            if ((chunk_idx < (args.size() - 1:Nat)) and (chunk.transactions.size() != 2000)) {
                                onError("chunk.transactions.size() != 2000 | chunk.transactions.size(): " # Nat.toText(chunk.transactions.size()));
                                return false;
                            };
                        Vector.add(
                            unordered,
                            {
                                start = args_starts[chunk_idx];
                                transactions = chunk.transactions;
                            },
                        );
                        };
                        chunk_idx += 1;
                    };
                };

                let sorted = Array.sort<TransactionUnordered>(Vector.toArray(unordered), func(a, b) = Nat.compare(a.start, b.start));

                for (u in sorted.vals()) {
                    if (u.start != mem.last_indexed_tx) {
                        onError("u.start != mem.last_indexed_tx | u.start: " # Nat.toText(u.start) # " mem.last_indexed_tx: " # Nat.toText(mem.last_indexed_tx) # " u.transactions.size(): " # Nat.toText(u.transactions.size()));
                        return false;
                    };
                    onRead(u.transactions, mem.last_indexed_tx);
                    mem.last_indexed_tx += u.transactions.size();
                    if (u.transactions.size() != 0) lastTxTime := u.transactions[u.transactions.size() - 1].timestamp;
                };

                if (rez.transactions.size() != 0) {
                    onRead(rez.transactions, mem.last_indexed_tx);
                    mem.last_indexed_tx += rez.transactions.size();
                    lastTxTime := rez.transactions[rez.transactions.size() - 1].timestamp;
                };
            };

            let inst_end = Prim.performanceCounter(1); // 1 is preserving with async
            onCycleEnd(inst_end - inst_start);

            quick_cycle;

        };

        /// Returns the last tx time or the current time if there are no more transactions to read
        public func getReaderLastTxTime() : Nat64 { 
            lastTxTime;
        };

        private func cycle_shell<system>() : async () {
            var quick = false;
            try {
                // We need it async or it won't throw errors
                quick := await cycle();
            } catch (e) {
                onError("cycle:" # Principal.toText(ledger_id) # ":" # Error.message(e));
            };

            if (started) ignore Timer.setTimer<system>(#seconds(if (quick) 0 else 2), cycle_shell);
        };

        public func start<system>() {
            if (started) Debug.trap("already started");
            started := true;
            ignore Timer.setTimer<system>(#seconds 2, cycle_shell);
        };

        public func stop() {
            started := false;
        }
    };

};
