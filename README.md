# devefi-icrc-ledger

## Install
```
mops add devefi-icrc-ledger
```

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