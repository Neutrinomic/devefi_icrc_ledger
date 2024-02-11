# devefi-icrc-ledger

## Install
```
mops add devefi-icrc-ledger
```

## Author's Statement 
(to be included in the beginning of audits and confirmed or denied)

This statement serves as a foundational guide for understanding the operational framework of our module in relation to transaction management:

1) Upon inclusion in the local queue, transactions attain a status of finality. This signifies that the module autonomously manages the dispatch process, obviating the need for developers to await confirmation.

2) Persistently, the system endeavors to register the transaction within the ledger. Despite any initial failures, the mechanism is designed to attempt indefinitely until successful registration is achieved.

3) It is important to note that the module cannot ensure the transmission of the precise amount initially intended due to potential variations in ledger fees during the transaction process. In the rare event of such fluctuations, the adjusted fee will be deducted from the transaction amount.

4) Furthermore, while the module efficiently processes transactions, it does not assure the preservation of their original sequential order.

5) The act of queueing and locally finalizing transactions does not instantaneously reflect changes in the remote ledger's balances. These updates will materialize subsequent to a delay, as the system processes the transactions.

6) Transaction confirmations are not reliant on callbacks but are determined by reading the ledger transaction log.
7) If the ledger experiences high transaction volumes, leading to delays in reading or reduced sending capabilities, there may be a lag in the local state synchronization.
8) The module's intended performance guarantees are contingent upon developers utilizing it exclusively for transactions, without bypassing its mechanisms (calling ledgers directly).
9) The retry functionality incorporates deduplication, which requires precise implementation. If deduplication or the transaction log is not correctly implemented, the system may not function as expected. The transaction window (TXWINDOW) is currently set to a fixed 24-hour period, with an expectation for ledgers to specify this window within their meta tags, since it's not fixed inside the standard.
10) Should a one-way transaction fail to send due to a network error, it will be retried in the subsequent cycle, occurring 2 seconds later. If the transaction is sent but fails to appear in the ledger, it will be retried after a 2-minute interval.
11) Upon initial activation, the system commences reading from a specified block (or the most recent one). Transactions predating this block are disregarded and will not be reflected in the local balances.

12) While reinstalling the canister is generally discouraged, should it become necessary under exceptional circumstances, it is crucial to ensure that all transaction hooks are meticulously managed to prevent them from processing the same events more than once.

13) Following the provided installation guidelines ensures the system's resilience through canister upgrades, restarts, or stops, maintaining both its queue and balances intact. This robustness extends to scenarios where the ledger itself may cease operations or undergo upgrades, safeguarding against inaccuracies in local balances or issues with the transaction queue.





Note: TXWINDOW features and fee to be implemented asap, but not there yet.


## Usage
Ignores transactions with amount less than fee and won't show them in onRecieve or keep their balance.

```motoko
import L "mo:devefi-icrc-ledger";
import Principal "mo:base/Principal";


actor class() = this {

    stable let lmem = L.LMem(); 
    let ledger = L.Ledger(lmem, "mxzaz-hqaaa-aaaar-qaada-cai", #last);
    ledger.onReceive(func (t) = ignore ledger.send({ to = t.from; amount = t.amount; from_subaccount = t.to.subaccount; }));
    
    // there are also onMint, onSent (from this canister), onBurn

    ledger.start();
    
    public func start() { 
         ledger.setOwner(this);
         };

    public query func getErrors() : async [Text] { 
        ledger.getErrors();
    };

    public query func getInfo() : async L.Info {
        ledger.getInfo();
    }
}

```