export const idlFactory = ({ IDL }) => {
  const anon_class_15_1 = IDL.Service({
    'get_errors' : IDL.Func([], [IDL.Nat, IDL.Nat, IDL.Text], ['query']),
    'start' : IDL.Func([], [], []),
    'stop' : IDL.Func([], [], []),
  });
  return anon_class_15_1;
};
export const init = ({ IDL }) => {
  return [IDL.Record({ 'userCanId' : IDL.Principal })];
};
