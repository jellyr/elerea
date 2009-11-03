{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-|

This is an experimental version of Elerea that does not build an
actual graph of the dataflow network, just maintains a list of actions
to update signals.  Each signal consists of a mutable variable, an
aging action and a finalising action.  The variables can only be
accessed through a sampling action, and they are only referred to in
the corresponding aging and finalising action.  These actions can be
accessed through weak pointers that get invalidated when all other
references to the corresponding variable are lost.

-}

module FRP.Elerea.Experimental.Simple
    ( Signal
    , SignalGen
    , createSampler
    , external
    , memo
    , delay
    , stateful
    , transfer
    , generator
    ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Fix
import Data.IORef
import Data.Maybe
import System.Mem.Weak

import FRP.Elerea.Experimental.WeakRef

-- | A signal is represented by a sampling computation.
newtype Signal a = S (IO a)
    deriving (Functor, Applicative, Monad)

-- | A dynamic set of actions to update a network without breaking
-- consistency.
type UpdatePool = [Weak (IO (),IO ())]

-- | A signal generator computes a signal structure and adds the new
-- variables to an existing update pool.
newtype SignalGen a = SG { unSG :: IORef UpdatePool -> IO a }

-- | The phases every signal goes through during a superstep.
data Phase a = Ready a | Aged a a

instance Functor SignalGen where
    fmap = (<*>).pure

instance Applicative SignalGen where
    pure = return
    (<*>) = ap

instance Monad SignalGen where
    return = SG . const . return
    SG g >>= f = SG $ \p -> g p >>= \x -> unSG (f x) p

instance MonadFix SignalGen where
    mfix f = SG $ \p -> mfix (($p).unSG.f)

-- | Embedding a signal into an 'IO' environment.  Repeated calls to
-- the computation returned cause the whole network to be updated, and
-- the current sample of the top-level signal is produced as a result.
createSampler :: SignalGen (Signal a) -- ^ the generator of the top-level signal
              -> IO (IO a)            -- ^ the computation to sample the signal
createSampler (SG gen) = do
  pool <- newIORef []
  (S sample) <- gen pool
  return $ do
    res <- sample
    let deref ptr = (fmap.fmap) ((,) ptr) (deRefWeak ptr)
    (ptrs,acts) <- unzip.catMaybes <$> (mapM deref =<< readIORef pool)
    writeIORef pool ptrs
    mapM_ fst acts
    mapM_ snd acts
    return res

-- | Auxiliary function used by all the primitives that create a
-- mutable variable.
addSignal :: (a -> IO a)      -- ^ sampling function
          -> (a -> IO ())     -- ^ aging function
          -> IORef (Phase a)  -- ^ the mutable variable behind the signal
          -> IORef UpdatePool -- ^ the pool of update actions
          -> IO (Signal a)
addSignal sample age ref pool = do
  let  sample' (Ready x)    = sample x
       sample' (Aged _ x)   = return x

       age' (Ready x)    = age x
       age' _            = return ()

       commit (Aged x _)  = Ready x
       commit _           = error "commit error: signal not aged"

  update <- mkWeakRef ref (age' =<< readIORef ref,modifyIORef ref commit) Nothing
  modifyIORef pool (update:)
  return (S $ sample' =<< readIORef ref)

-- | The 'delay' transfer function emits the value of a signal from
-- the previous superstep, starting with the filler value given in the
-- first argument.
delay :: a                    -- ^ initial output
      -> Signal a             -- ^ the signal to delay
      -> SignalGen (Signal a)
delay x0 (S s) = SG $ \pool -> do
  ref <- newIORef (Ready x0)

  let age x = s >>= \x' -> x' `seq` writeIORef ref (Aged x' x)

  addSignal return age ref pool

-- | Memoising combinator.  It can be used to cache results of
-- applicative combinators in case they are used in several places.
-- Other than that, it is equivalent to 'return'.
memo :: Signal a             -- ^ signal to memoise
     -> SignalGen (Signal a)
memo (S s) = SG $ \pool -> do
  ref <- newIORef (Ready undefined)

  let  sample _ = s >>= \x -> writeIORef ref (Aged undefined x) >> return x       
       age _ = writeIORef ref . Aged undefined =<< s

  addSignal sample age ref pool

-- | A reactive signal that takes the value to output from a monad
-- carried by its input when a boolean control signal is true,
-- otherwise it repeats its previous output.  It is possible to create
-- new signals in the monad.
generator :: Signal Bool          -- ^ control (trigger) signal
          -> (SignalGen a)        -- ^ the generator of the initial output
          -> Signal (SignalGen a) -- ^ a stream of generators to potentially run
          -> SignalGen (Signal a)
generator (S ctr) (SG gen0) (S gen) = SG $ \pool -> do
  ref <- newIORef . Ready =<< gen0 pool

  let  next x = ctr >>= \b -> if b then ($pool).unSG =<< gen else return x
       sample x = next x >>= \x' -> writeIORef ref (Aged x' x') >> return x'
       age x = next x >>= \x' -> writeIORef ref (Aged x' x')

  addSignal sample age ref pool

-- | A signal that can be directly fed through the sink function
-- returned.  This can be used to attach the network to the outer
-- world.
external :: a                         -- ^ initial value
         -> IO (Signal a, a -> IO ()) -- ^ the signal and an IO function to feed it
external x = do
  ref <- newIORef x
  return (S (readIORef ref), writeIORef ref)

-- | A pure stateful signal.  The initial state is the first output.
-- It is equivalent to the following expression:
-- 
-- @
--  stateful x0 f = 'mfix' $ \sig -> 'delay' x0 (f '<$>' sig)
-- @
stateful :: a                    -- ^ initial state
         -> (a -> a)             -- ^ state transformation
         -> SignalGen (Signal a)
stateful x0 f = mfix $ \sig -> delay x0 (f <$> sig)

-- | A stateful transfer function.  The current input affects the
-- current output, i.e. the initial state given in the first argument
-- is considered to appear before the first output, and can never be
-- observed.  It is equivalent to the following expression:
-- 
-- @
--  transfer x0 f s = 'mfix' $ \sig -> 'liftA2' f s '<$>' 'delay' x0 sig
-- @
transfer :: a                    -- ^ initial internal state
         -> (t -> a -> a)        -- ^ state updater function
         -> Signal t             -- ^ input signal
         -> SignalGen (Signal a)
transfer x0 f s = mfix $ \sig -> liftA2 f s <$> delay x0 sig