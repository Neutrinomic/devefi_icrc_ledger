
export const init = ({ IDL }) => {
  const MetadataValue = IDL.Variant({
    'Int' : IDL.Int,
    'Nat' : IDL.Nat,
    'Blob' : IDL.Vec(IDL.Nat8),
    'Text' : IDL.Text,
  });
  const Subaccount = IDL.Vec(IDL.Nat8);
  const Account = IDL.Record({
    'owner' : IDL.Principal,
    'subaccount' : IDL.Opt(Subaccount),
  });
  const ChangeFeeCollector = IDL.Variant({
    'SetTo' : Account,
    'Unset' : IDL.Null,
  });
  const FeatureFlags = IDL.Record({ 'icrc2' : IDL.Bool });
  const UpgradeArgs = IDL.Record({
    'token_symbol' : IDL.Opt(IDL.Text),
    'transfer_fee' : IDL.Opt(IDL.Nat),
    'metadata' : IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, MetadataValue))),
    'maximum_number_of_accounts' : IDL.Opt(IDL.Nat64),
    'accounts_overflow_trim_quantity' : IDL.Opt(IDL.Nat64),
    'change_fee_collector' : IDL.Opt(ChangeFeeCollector),
    'max_memo_length' : IDL.Opt(IDL.Nat16),
    'token_name' : IDL.Opt(IDL.Text),
    'feature_flags' : IDL.Opt(FeatureFlags),
  });
  const InitArgs = IDL.Record({
    'decimals' : IDL.Opt(IDL.Nat8),
    'token_symbol' : IDL.Text,
    'transfer_fee' : IDL.Nat,
    'metadata' : IDL.Vec(IDL.Tuple(IDL.Text, MetadataValue)),
    'minting_account' : Account,
    'initial_balances' : IDL.Vec(IDL.Tuple(Account, IDL.Nat)),
    'maximum_number_of_accounts' : IDL.Opt(IDL.Nat64),
    'accounts_overflow_trim_quantity' : IDL.Opt(IDL.Nat64),
    'fee_collector_account' : IDL.Opt(Account),
    'archive_options' : IDL.Record({
      'num_blocks_to_archive' : IDL.Nat64,
      'max_transactions_per_response' : IDL.Opt(IDL.Nat64),
      'trigger_threshold' : IDL.Nat64,
      'max_message_size_bytes' : IDL.Opt(IDL.Nat64),
      'cycles_for_archive_creation' : IDL.Opt(IDL.Nat64),
      'node_max_memory_size_bytes' : IDL.Opt(IDL.Nat64),
      'controller_id' : IDL.Principal,
    }),
    'max_memo_length' : IDL.Opt(IDL.Nat16),
    'token_name' : IDL.Text,
    'feature_flags' : IDL.Opt(FeatureFlags),
  });
  const LedgerArg = IDL.Variant({
    'Upgrade' : IDL.Opt(UpgradeArgs),
    'Init' : InitArgs,
  });
  return [LedgerArg];
};
