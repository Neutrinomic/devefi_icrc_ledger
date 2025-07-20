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
import Ver1 "./memory/v1";
import MU "mo:mosup";

module {
    public type Transaction = Ledger.Transaction;

    public module Mem {
        public module Reader {
            public let V1 = Ver1.Reader;
        };
    };

    type TransactionUnordered = {
            start : Nat;
            transactions : [Ledger.Transaction];
        };
        
    let VM = Mem.Reader.V1;

    public class Reader<system>({
        xmem : MU.MemShell<VM.Mem>;
        ledger_id : Principal;
        start_from_block: {#id:Nat; #last};
        onError : (Text) -> (); // If error occurs during following and processing it will return the error
        onCycleEnd : (Nat64) -> (); // Measure performance of following and processing transactions. Returns instruction count
        onRead : ([Ledger.Transaction], Nat) -> ();
        maxSimultaneousRequests : Nat;
        readingEnabled : () -> Bool;
    }) {
        let mem = MU.access(xmem);
        let ledger = actor (Principal.toText(ledger_id)) : Ledger.Self;

        // Last transaction time and last update time will reset on upgrade
        var lastTxTime : Nat64 = 0;
        var lastUpdate : Nat64 = 0;

        let maxTransactionsInCall:Nat = 2000;

        var lock:Int = 0;
        let MAX_TIME_LOCKED:Int = 120_000_000_000; // 120 seconds

        let CYCLE_RECURRING_TIME_SEC = 2;
        
        /// Called every CYCLE_RECURRING_TIME_SEC seconds
        /// Reads transactions from ledger and archives and sends them to onRead callback
        /// # Precondition: mem.last_indexed_tx is the last indexed transaction in the ledger
        /// # Precondition: The ledger and archive have enough cycles
        /// # Precondition: log_length - should be chain_length - the size of the whole blockchain, not zero, not the response length
        /// # Precondition: When get_transactions asks for 'start' the response has to start from there and return `length` number of blocks, not more, not less.
        /// # Precondition: When it returns current and archived transactions, it should make sure, when these get gathered, no block is skipped or duplicated. So that all gathered transactions have same requested `length`, start from 'start' and the last block index is 'start' + 'length' 
        ///
        /// # Invariant: We never send the same transaction twice to onRead
        /// # Invariant: We read transactions in order and never skip any
        /// # Postcondition: mem.last_indexed_tx is updated to the last indexed transaction in the ledger
        /// # Postcondition: lastTxTime is updated to the last transaction time
        /// # Postcondition: lastUpdate is updated to the current time
        /// # Postcondition: if something went wrong, we will retry indefinitely
        /// # Postcondition: if a call doesn't arrive on time we will unlock. Once it arrives it won't be processed because of the reentrancy protections
        private func cycle() : async () {
            if (not readingEnabled()) return;

            // Protection against reentrancy
            // If the cycle is called again before the previous cycle is finished, we return
            let now = Time.now();
            if (now - lock < MAX_TIME_LOCKED) return;
            lock := now;
            var reached_end = false;
            // Measure the performance of the cycle
            let inst_start = Prim.performanceCounter(1); // 1 is preserving with async

            // When we run for the first time we decide where to start reading from
            if (mem.last_indexed_tx == 0) {
                switch(start_from_block) {
                    case (#id(id)) {
                        mem.last_indexed_tx := id;
                    };
                    case (#last) {
                        // If we start from the last transaction, we need to get the last transaction from the ledger
                        let rez = await (with timeout = 20) ledger.get_transactions({
                            start = 0;
                            length = 0;
                        });

                        // If the ledger is empty, we return
                        if (rez.log_length == 0) {
                            lock := 0;
                            return;
                        };
                        // We set the last indexed transaction to the last transaction in the ledger
                        // log_length is the number of transactions in the ledger
                        mem.last_indexed_tx := rez.log_length -1;
                    };
                };
            };

            // We start reading from the last indexed transaction
            let query_start = mem.last_indexed_tx;
            let rez = try {

                // maxTransactionsInCall is 2000 for standard ledgers
                // if the call doesn't arrive in 20 seconds, it will be cancelled (best-effort)
                // and throw an error
                await (with timeout = 20) ledger.get_transactions({
                start = query_start;
                length = maxTransactionsInCall * maxSimultaneousRequests;
            });

            // The resulting transactions always start from the requested start
            // We get exactly as many transactions as we asked for
            } catch (e) {
                    onError("Error in ledger get_transactions: " # Error.message(e));
                    lock := 0;
                    return;
            };

            // Protection against reentrancy - if the last indexed transaction has changed, we unlock and return
            if (query_start != mem.last_indexed_tx) {lock:=0; return;};

            if (rez.transactions.size() < maxTransactionsInCall) reached_end := true;
            
            // If there are no archived transactions, we can just process the transactions that are inside the ledger and not inside archive
            if (rez.archived_transactions.size() == 0) {

                

                if (rez.transactions.size() != 0) {
                        
                    // Protection against reentrancy and corrupt responses
                    if (rez.first_index != mem.last_indexed_tx) {
                        onError("ledger.get_transactions start: " # Nat.toText(query_start) # " length: " # Nat.toText(maxTransactionsInCall * maxSimultaneousRequests) # " rez.first_index !== mem.last_indexed_tx | rez.first_index: " # Nat.toText(rez.first_index) # " mem.last_indexed_tx: " # Nat.toText(mem.last_indexed_tx) # " rez.transactions.size(): " # Nat.toText(rez.transactions.size()));
                        lock := 0;
                        return;
                    };
                    

                    // We can just process the transactions that are inside the ledger and not inside archive
                    onRead(rez.transactions, mem.last_indexed_tx);

                    // We update the last indexed transaction
                    mem.last_indexed_tx += rez.transactions.size();
            
                    // We update the last transaction time
                    lastTxTime := rez.transactions[rez.transactions.size() - 1].timestamp;
                };
            
            } else {
                // If there are archived transactions, we need to collect them and get them in order
                // We need to collect transactions from archive and get them in order
                let unordered = Vector.new<TransactionUnordered>(); 
       
                // The ledger returns an array of archived transactions (could be in any order and any size of chunks)
                // It provides chunks of transactions pointing to archive canister callbacks
                // which need to be called in order to get the transactions
                
                for (atx in rez.archived_transactions.vals()) {

                    // When given map of archived transactions, we split into chunks of maxTransactionsInCall
                    // and send them to the archive callback
                    
                    let args_starts = Array.tabulate<Nat>(Nat.min(maxSimultaneousRequests, (atx.length + maxTransactionsInCall -1)/maxTransactionsInCall), func(i) = atx.start + i*maxTransactionsInCall);
                    // Example atx.start = 100, atx.length = 5000
                    // Array.tabulate(size, fn) will result in: 100, 2100, 4100, ... splitting atx.length into chunks of maxTransactionsInCall

                    let args = Array.map<Nat, Ledger.GetBlocksRequest>( args_starts, func(i) = {start = i; length = if (i - atx.start:Nat + maxTransactionsInCall <= atx.length) maxTransactionsInCall else atx.length + atx.start - i } );
                    // Array.map will result in: {start = 100; length = 2000}, {start = 2100; length = 2000},... {start = 4100; length = 1100} 
                    // (Calc: (4100 - 100 + 2000) = 6000 <= 5000 -> false. Then length: 5100 + 100 - 4100 = 1100)

                    // Optimisation possible: If atx.length is maxTransactionsInCall, we will make one more empty call to the archive callback with length = 0

                    // Store the promises in a list
                    var buf = List.nil<async Ledger.TransactionRange>();

                    // Store the results in a list
                    var data = List.nil<Ledger.TransactionRange>();

                    // Calling all archive callbacks in parallel
                    for (arg in args.vals()) {
                        // The calls are sent here without awaiting anything
                        Debug.print("archived_transactions: " # debug_show(arg));
                        let promise = (with timeout = 20) atx.callback(arg);
                        buf := List.push(promise, buf); 
                    };

                    // Awaiting all archive callbacks in sequential order
                    for (promise in List.toIter(buf)) {
                        // Await results of all promises. We recieve them in sequential order
                        try {
                        data := List.push(await promise, data);
                        } catch (e) {
                            // If any of the archive callbacks fail, we unlock and return
                            onError("Error in archive callback: " # Error.message(e));
                            lock := 0;
                            return;
                        }
                    };

                    // Process all chunks once we have all of them
                    let chunks = List.toArray(data);
                    var chunk_idx = 0;
                    for (chunk in chunks.vals()) {
                        if (chunk.transactions.size() > 0) {
                            // If chunks (except the last one) are smaller than 2000 tx then implementation is strange we unlock and return
                            if ((chunk_idx < (args.size() - 1:Nat)) and (chunk.transactions.size() != maxTransactionsInCall)) {
                                onError("chunk.transactions.size() != " # Nat.toText(maxTransactionsInCall) # " | chunk.transactions.size(): " # Nat.toText(chunk.transactions.size()));
                                lock := 0;
                                return;
                            };

                            // Add the chunk to the unordered list
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

                // Sort the unordered list by start index
                let sorted = Array.sort<TransactionUnordered>(Vector.toArray(unordered), func(a, b) = Nat.compare(a.start, b.start));

                // Process the unordered list
                for (u in sorted.vals()) {
                    // Protection against reentrancy - if the last indexed transaction has changed, we unlock and return
                    if (u.start != mem.last_indexed_tx) {
                        onError("u.start != mem.last_indexed_tx | u.start: " # Nat.toText(u.start) # " mem.last_indexed_tx: " # Nat.toText(mem.last_indexed_tx) # " u.transactions.size(): " # Nat.toText(u.transactions.size()));
                        lock := 0;
                        return;
                    };

                    // Send the transactions to the onRead callback
                    onRead(u.transactions, mem.last_indexed_tx);

                    // Update the last indexed transaction
                    mem.last_indexed_tx += u.transactions.size();

                    // Update the last transaction time
                    if (u.transactions.size() != 0) lastTxTime := u.transactions[u.transactions.size() - 1].timestamp;
                };

                // Process the transactions that are inside the ledger and not inside archive
                if (rez.transactions.size() != 0) {
                    // Protection against reentrancy - if the last indexed transaction has changed, we unlock and return
                    if (rez.first_index != mem.last_indexed_tx) {
                        onError("rez.first_index !== mem.last_indexed_tx | rez.first_index: " # Nat.toText(rez.first_index) # " mem.last_indexed_tx: " # Nat.toText(mem.last_indexed_tx) # " rez.transactions.size(): " # Nat.toText(rez.transactions.size()));
                        lock := 0;
                        return;
                    };

                    // Send the transactions to the onRead callback
                    onRead(rez.transactions, mem.last_indexed_tx);

                    // Update the last indexed transaction
                    mem.last_indexed_tx += rez.transactions.size();

                    // Update the last transaction time
                    lastTxTime := rez.transactions[rez.transactions.size() - 1].timestamp;
                };
            };

            // Measure the performance of the cycle
            let inst_end = Prim.performanceCounter(1); // 1 is preserving with async
            onCycleEnd(inst_end - inst_start);

            // only if we reached the end we update the last update time, so that new retry transactions wont be made if we are lagging behind
            if (reached_end) lastUpdate := Nat64.fromNat(Int.abs(Time.now()));

            // Unlock the cycle
            lock := 0;
        };

        /// Returns the last tx time or the current time if there are no more transactions to read
        public func getReaderLastTxTime() : Nat64 { 
            lastTxTime;
        };

        public func getReaderLastUpdate() : Nat64 {
            lastUpdate;
        };

        public func getLastReadTxIndex() : Nat {
            mem.last_indexed_tx;
        };

        ignore Timer.setTimer<system>(#seconds 0, cycle);
        ignore Timer.recurringTimer<system>(#seconds CYCLE_RECURRING_TIME_SEC, cycle);
    };

};
