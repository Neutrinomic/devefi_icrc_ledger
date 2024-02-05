# devefi-icrc-ledger

## Install
```
mops add devefi-icrc-ledger
```

## Usage
```motoko
import L "mo:devefi-icrc-ledger";
import Principal "mo:base/Principal";


actor class() = this {

    stable let lmem = L.LMem(); 
    let ledger = L.Ledger(lmem, "mxzaz-hqaaa-aaaar-qaada-cai");
    ledger.onReceive(func (t) = ignore ledger.send({ to = t.from; amount = t.amount; from_subaccount = t.to.subaccount; }));
    
    ledger.start();
    
    public func start() { 
         Debug.print("started");
         ledger.setOwner(this);
         };

    public query func get_errors() : async [Text] { 
        ledger.get_errors();
    };

    public query func de_bug() : async Text {
        ledger.de_bug();
    }
}

```