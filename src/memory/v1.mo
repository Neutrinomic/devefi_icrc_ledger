import Map "mo:map/Map";
import BTree "mo:stableheapbtreemap/BTree";
import MU "mo:mosup";

module {

    public module Ledger { 

        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            reader = Reader.new();
            sender = Sender.new();
            accounts = Map.new<Blob, AccountMem>();
            var meta = null;
            minter = null;
            var next_tx_id : Nat64 = 0;
        });

        public type AccountMem = {
            var balance : Nat;
            var in_transit : Nat;
        };

        public type Mem = {
            reader : MU.MemShell<Reader.Mem>;
            sender : MU.MemShell<Sender.Mem>;
            accounts : Map.Map<Blob, AccountMem>;
            var meta : ?Meta;
            var next_tx_id : Nat64;
        };

        public type Meta = {
            symbol : Text;
            decimals : Nat8;
            minter : ?Account;
            fee : Nat;
        };

    };

    public module Reader {
        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            var last_indexed_tx = 0;
        });
        public type Mem = {
            var last_indexed_tx : Nat;
        };
    };

    public module Sender {
        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            transactions = BTree.init<Nat64, Transaction>(?16);
        });
   
        public type Transaction = {
            amount: Nat;
            to : Account;
            from_subaccount : ?Blob;
            var created_at_time : Nat64; 
            memo : Blob;
            var tries: Nat;
        };

        public type Mem = {
            transactions : BTree.BTree<Nat64, Transaction>;
        };
    };

    public type Account = { owner : Principal; subaccount : ?Blob };

}