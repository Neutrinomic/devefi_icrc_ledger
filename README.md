# DeVeFi Ledger Middleware

The DeVeFi Ledger Middleware enhances the Internet Computer by introducing internal atomicity for DeFi applications, designating canisters as the sole authorities over their controlled tokens. This approach directly tackles the challenges posed by asynchronous communication, ensuring transactions within the canister achieve internal atomicity before syncing with the master ledger. Another key feature is its ability to automatically receive notifications about incoming transactions.

## Install
```
mops add devefi-icrc-ledger
```

## Enhanced Transaction Management System
This guide explains the operational framework of our module, focusing on transaction management. It highlights how the module simplifies and enhances transaction processing.

#### 1. Autonomous Transaction Finalization in Local Queues
Upon inclusion in the local queue, transactions attain a status of finality. This signifies that the module autonomously manages the dispatch process, obviating the need for developers to await confirmation.

#### 2. Persistent Transaction Registration and Retry Mechanism
Persistently, the system endeavors to register the transaction within the ledger. Despite any initial failures, the mechanism is designed to attempt indefinitely until successful registration is achieved.

#### 3. Handling Fee Variations in Transaction Amounts
It is important to note that the module cannot ensure the transmission of the precise amount initially intended due to potential variations in ledger fees during the transaction process. In the rare event of such fluctuations, the adjusted fee will be deducted from the transaction amount. The fee gets refreshed every 600 cycles (every ~20min).

#### 4. Sequential Order and Transaction Processing Limitations 
Furthermore, while the module efficiently processes transactions, it does not assure the preservation of their original sequential order.

#### 5. Delayed Reflection of Transactions in Remote Ledger Balances
The act of queueing and locally finalizing transactions does not instantaneously reflect changes in the remote ledger's balances. These updates will materialize subsequent to a delay, as the system processes the transactions.

#### 6. Determining Transaction Confirmations via Ledger Logs
Transaction confirmations are not reliant on callbacks but are determined by reading the ledger transaction log.

#### 7. Impact of High Transaction Volumes on State Synchronization
If the ledger experiences high transaction volumes, leading to delays in reading or reduced sending capabilities, there may be a lag in the local state synchronization.

#### 8. Performance Guarantees and Proper Use of Transaction Modules
The module's intended performance guarantees are contingent upon developers utilizing it exclusively for transactions, without bypassing its mechanisms (calling ledgers directly).

#### 9. Deduplication and Transaction Window Management in Retry Functionality
The retry functionality incorporates deduplication, which requires precise implementation. If deduplication or the transaction log is not correctly implemented, the system may not function as expected. The transaction window (TXWINDOW) is currently set to a fixed 24-hour period, with an expectation for ledgers to specify this window within their meta tags, since it's not fixed inside the standard.

#### 10. Retry Mechanism for Failed One-Way Transactions
Should a one-way transaction fail to send due to a network error, it will be retried in the subsequent cycle, occurring 2 seconds later. If the transaction is sent but fails to appear in the ledger, it will be retried after a 2-minute interval.

#### 11. Initial System Activation and Transaction Reading Parameters
Upon initial activation, the system commences reading from a specified block (or the most recent one). Transactions predating this block are disregarded and will not be reflected in the local balances.

#### 12. Managing Transaction Hooks During Canister Reinstallation
While reinstalling the canister is generally discouraged, should it become necessary under exceptional circumstances, it is crucial to ensure that all transaction hooks are meticulously managed to prevent them from processing the same events more than once.

#### 13. System Resilience Against Canister and Ledger Disruptions
Following the provided installation guidelines ensures the system's resilience through canister upgrades, restarts, or stops, maintaining both its queue and balances intact. This robustness extends to scenarios where the ledger itself may cease operations or undergo upgrades, safeguarding against inaccuracies in local balances or issues with the transaction queue.

#### 14. Retry Strategy and Timing Adjustments for Unregistered Transactions
The system will try to resend the transaction multiple times during the first `transactionWindowNanos` (Fixed currently at 24hours). There is a very small chance that under heavy load the ledger won't register it. The system will adjust created_at to fit to the new window `retryWindow` equal to `2x(transactionWindowNanos + permittedDriftNanos)`, but only if the reader is following transaction history and not too far behind `allowedLagToChangeWindow` (15 minutes). With the current settings, this means if transaction fails to register within the first 24 hours, it will be retried every 48hours for 24 hours (between 48h - 75h, 96h - 120h,.. until the end of times or until transaction amount is < fee)

#### 15. Error Handling and Infinite Loop Prevention in Transaction Processing
Hooks must not trap because Motoko is unable to catch synchronous errors. In the event of an error, any state changes will be reverted, and the system will enter an infinite loop, repeatedly processing the same transactions until an upgrade rectifies the issue. Additionally, developers should avoid setting Timers within synchronous hooks, as this can disrupt the rollback mechanism.

#### 16. Balance Management and Transaction Dispatch Mechanism
When a transaction is enqueued, its amount is deducted from the balance. This process involves maintaining two figures: balance, which represents the actual balance, and in_transit, which tracks the amount being dispatched through outgoing transactions. This mechanism prevents the system from initiating multiple transactions without sufficient balance.


### Test - 1 - Dynamic Ledger Endurance Analysis

#### Methodology
We executed tests on a locally deployed ledger canister, specifically the latest one from the SNSW. The testing process involved receiving a large volume of tokens and dividing these by sending 10,000 transactions to various accounts. These recipient accounts then forwarded the transactions to other accounts until the transaction amount fell below the transaction fee. This strategy allowed us to initiate with sufficient tokens for 20,000 transactions and assess the total number of transactions successfully processed at the end of the test.

Throughout the testing phase, we frequently stopped and restarted both the test canister equipped with this library and the ledger itself. Additionally, we performed several upgrades to the test canister during the testing period. Despite these interruptions, our trials consistently showed that no transactions were lost, whether in the sending or receiving phases.

We further tested the system's resilience by intentionally causing the replica to generate errors during the sending process. These induced errors did not disrupt the queue's functionality.

#### Important Notice
This testing was conducted exclusively with Dfinity's icrc ledger, excluding the ICP ledger due to its distinct transaction log structure. It is important to note that the performance and reliability observed may not directly translate to other ledgers. The functionality of this library is contingent upon two key features: deduplication and the get_transactions method, which are slated for replacement with the upcoming ICRC-3 protocol. For optimal performance, both features must operate flawlessly.

#### Throughput Per Ledger
Sending to Library Queue: Limited only by canister memory and instruction limits.
Sending from Queue to Ledger: ~45 tx/s (could be double if both canisters are on the same subnet or tested in local replica)
Reading from Ledger: ~250 tx/s

### Test - 2 - Integrity Verification Protocol

#### Methodology

Execute 20,000 transactions (the ledger is configured to split the archive after every 10,000 transactions). Obtain a hash from all account balances owned by the canister. Reinstall the canister and start from block 0 (removing hooks). Generate a second hash and compare it to the first; the two hashes should match. Additionally, retrieve all accounts using the new accounts function and directly check their balances by calling the ledger. Compare both sets of balances to ensure they match. The library has passed this test multiple times.


## Usage
Ignores transactions with amount less than fee and won't show them in onRecieve or keep their balance.

```motoko
import L "mo:devefi-icrc-ledger";
import Principal "mo:base/Principal";


actor class() = this {

    stable let lmem = L.LMem(); // has to be stable
    
    let ledger = L.Ledger(lmem, "mxzaz-hqaaa-aaaar-qaada-cai", #last);

    ledger.onReceive(func (t) = ignore ledger.send({ to = t.from; amount = t.amount; from_subaccount = t.to.subaccount; }));
    
    // there are also onMint, onSent (from this canister), onBurn

    ledger.start();
    
    public shared({caller}) func start() { 
         assert(Principal.isController(caller));
         ledger.setOwner(this); // required to be called once when canister is installed
         };

    public query func getErrors() : async [Text] { 
        ledger.getErrors(); // When running timers, if there is an error it will show here and nowhere else. (Hooks are called by timers too)
    };

    public query func getInfo() : async L.Info {
        ledger.getInfo();
    }
}

```