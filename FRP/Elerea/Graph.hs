{-# LANGUAGE ExistentialQuantification #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

{-|

This module provides some means to visualise the signal structure.

-}

module FRP.Elerea.Graph (signalToDot) where

import Control.Monad
import Data.IORef
import Data.Maybe
import qualified Data.Map as Map
import Foreign.Ptr
import Foreign.StablePtr
import FRP.Elerea.Internal

type Id = Int

type SignalStore = Map.Map Id SignalInfo

data SignalInfo
    = Const
    | Stateful
    | Transfer Id
    | App Id Id
    | Latcher Id Id Id
    | External
    | Lift1 Id
    | Lift2 Id Id
    | Lift3 Id Id Id
    | Lift4 Id Id Id Id
    | Lift5 Id Id Id Id Id
    | None

getPtr :: a -> IO Id
getPtr x = fmap (fromIntegral . ptrToIntPtr . castStablePtrToPtr) (newStablePtr x)

buildStore :: SignalStore -> Signal a -> IO (Id,SignalStore)
buildStore st (S r) = do
  p <- getPtr r
  case Map.lookup p st of
    Just _  -> return (p,st)
    Nothing -> do Ready s <- readIORef r  
                  st' <- insertSignal st p s
                  return (p,st')

insertSignal :: SignalStore -> Id -> SignalNode a -> IO SignalStore
insertSignal st p (SNK _) = return (Map.insert p Const st)
insertSignal st p (SNS _ _) = return (Map.insert p Stateful st)
insertSignal st p (SNT s _ _) = do
  (s',st') <- buildStore (Map.insert p None st) s
  return (Map.insert p (Transfer s') st')
insertSignal st p (SNA sf sx) = do
  (sf',st') <- buildStore (Map.insert p None st) sf
  (sx',st'') <- buildStore st' sx
  return (Map.insert p (App sf' sx') st'')
insertSignal st p (SNE s e ss) = do
  (s',st') <- buildStore (Map.insert p None st) s
  (e',st'') <- buildStore st' e
  (ss',st''') <- buildStore st'' ss
  return (Map.insert p (Latcher s' e' ss') st''')
insertSignal st p (SNR _) = return (Map.insert p External st)
insertSignal st p (SNKA (S r) _) = do
  Ready s <- readIORef r
  insertSignal st p s
insertSignal st p (SNL1 _ s1) = do
  (s1',st') <- buildStore (Map.insert p None st) s1
  return (Map.insert p (Lift1 s1') st')
insertSignal st p (SNL2 _ s1 s2) = do
  (s1',st') <- buildStore (Map.insert p None st) s1
  (s2',st'') <- buildStore st' s2
  return (Map.insert p (Lift2 s1' s2') st'')
insertSignal st p (SNL3 _ s1 s2 s3) = do
  (s1',st') <- buildStore (Map.insert p None st) s1
  (s2',st'') <- buildStore st' s2
  (s3',st''') <- buildStore st'' s3
  return (Map.insert p (Lift3 s1' s2' s3') st''')
insertSignal st p (SNL4 _ s1 s2 s3 s4) = do
  (s1',st') <- buildStore (Map.insert p None st) s1
  (s2',st'') <- buildStore st' s2
  (s3',st''') <- buildStore st'' s3
  (s4',st'''') <- buildStore st''' s4
  return (Map.insert p (Lift4 s1' s2' s3' s4') st'''')
insertSignal st p (SNL5 _ s1 s2 s3 s4 s5) = do
  (s1',st') <- buildStore (Map.insert p None st) s1
  (s2',st'') <- buildStore st' s2
  (s3',st''') <- buildStore st'' s3
  (s4',st'''') <- buildStore st''' s4
  (s5',st''''') <- buildStore st'''' s5
  return (Map.insert p (Lift5 s1' s2' s3' s4' s5') st''''')

nodeLabel :: Maybe Id -> SignalInfo -> [Char]
nodeLabel id node = case node of
                      Const           -> "const"
                      Stateful        -> "stateful"
                      Transfer _      -> "transfer"
                      App _ _         -> "app"
                      Latcher _ _ _   -> "latcher"
                      External        -> "external"
                      Lift1 _         -> "fun1"
                      Lift2 _ _       -> "fun2"
                      Lift3 _ _ _     -> "fun3"
                      Lift4 _ _ _ _   -> "fun4"
                      Lift5 _ _ _ _ _ -> "fun5"
                      None            -> "NONE"
                    ++ (maybe "" show id)

{-|

Traversing the network starting from the given signal and converting
it into a string containing the graph in Graphviz
(<http://www.graphviz.org/>) dot format.  Stateful nodes are coloured
according to their type.

Because of the fact that Elerea primitives are not referentially
transparent, the results might differ depending on whether this
function is called before or after sampling (this also affects the
actual network!), but the networks should be still equivalent.

-}

signalToDot :: Signal a -> IO String
signalToDot s = do
  (_,st) <- buildStore Map.empty s
  let rules = map mkRule (Map.assocs st)
      mkRule (id,n) = "  " ++ name ++ attrs ++ edges
          where name = nodeLabel (Just id) n
                attrs = mkLabel (nodeLabel Nothing n) ("style=filled,fillcolor=\"#" ++ nodeCol ++ "\",shape=" ++ nodeShape)
                edges = case n of
                  Transfer s           -> mkEdge s "\"\""
                  App sf sx            -> mkEdge sf "f" ++ mkEdge sx "x"
                  Latcher s e ss       -> mkEdge s "init" ++ mkEdge e  "ctl" ++ mkEdge ss "\"\""
                  Lift1 s1             -> mkEdge s1 "x1"
                  Lift2 s1 s2          -> mkEdge s1 "x1" ++ mkEdge s2 "x2"
                  Lift3 s1 s2 s3       -> mkEdge s1 "x1" ++ mkEdge s2 "x2" ++ mkEdge s3 "x3"
                  Lift4 s1 s2 s3 s4    -> mkEdge s1 "x1" ++ mkEdge s2 "x2" ++ mkEdge s3 "x3" ++ mkEdge s4 "x4"
                  Lift5 s1 s2 s3 s4 s5 -> mkEdge s1 "x1" ++ mkEdge s2 "x2" ++ mkEdge s3 "x3" ++ mkEdge s4 "x4" ++ mkEdge s5 "x5"
                  _                    -> ""
                mkEdge endId label = "  " ++ name ++ " -> " ++
                                     nodeLabel (Just endId) (st Map.! endId) ++
                                     mkLabel label "dir=back"
                mkLabel name attrs = " [label=" ++ name ++ "," ++ attrs ++ "];\n"
                nodeCol = case n of
                  Transfer _    -> "ffcc99"
                  Latcher _ _ _ -> "99ccff"
                  External      -> "ccff99"
                  Stateful      -> "ffffcc"
                  _             -> "ffffff"
                nodeShape = case n of
                  Transfer _    -> "diamond"
                  Latcher _ _ _ -> "hexagon"
                  External      -> "invtriangle"
                  _             -> "ellipse"
  return $ "digraph G {\n" ++ concat rules ++ "}\n"
