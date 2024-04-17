# Simple state monad represented as
#
#     stateMonad s a = s -> { state : s; value : a }
#
{ ... }:

rec {
  #
  # Monad
  #

  # Type: stateMonad s a -> (a -> stateMonad s b) -> stateMonad s b
  bind = action: f: state:
    let
      afterAction = action state;
    in
    (f afterAction.value) afterAction.state;

  # Type: stateMonad s a -> stateMonad s b -> stateMonad s b
  after = action1: action2: state: action2 (action1 state).state;

  # Type: stateMonad s (stateMonad s a) -> stateMonad s a
  join = action: bind action (action': action');

  # Type: [a] -> (a -> stateMonad s b) -> stateMonad s null
  for_ = xs: f:
    builtins.foldl'
      (laterAction: x:
        after (f x) laterAction
      )
      (pure null)
      xs;

  #
  # Applicative
  #

  # Type: a -> stateMonad s a
  pure = value: state: { inherit state value; };

  # TODO(sterni): <*>, lift2, …

  #
  # Functor
  #

  # Type: (a -> b) -> stateMonad s a -> stateMonad s b
  fmap = f: action: bind action (result: pure (f result));

  #
  # State Monad
  #

  # Type: (s -> s) -> stateMonad s null
  modify = f: state: { value = null; state = f state; };

  # Type: stateMonad s s
  get = state: { value = state; inherit state; };

  # Type: s -> stateMonad s null
  set = new: modify (_: new);

  # Type: str -> stateMonad set set.${str}
  getAttr = attr: fmap (state: state.${attr}) get;

  # Type: str -> (any -> any) -> stateMonad s null
  modifyAttr = attr: f: modify (state: state // {
    ${attr} = f state.${attr};
  });

  # Type: str -> any -> stateMonad s null
  setAttr = attr: value: modifyAttr attr (_: value);

  # Type: s -> stateMonad s a -> a
  run = state: action: (action state).value;
}
