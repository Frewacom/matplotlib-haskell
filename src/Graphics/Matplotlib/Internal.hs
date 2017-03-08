{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, FlexibleContexts, ExtendedDefaultRules #-}
-- |
-- Internal representations of the Matplotlib data. These are not API-stable
-- and may change. You can easily extend the provided bindings without relying
-- on the internals exposed here but they are provided just in case.
module Graphics.Matplotlib.Internal where
import System.IO.Temp
import System.Process
import Data.Aeson
import Control.Monad
import System.IO
import qualified Data.ByteString.Lazy as B
import Data.List
import Control.Exception
import qualified Data.Sequence as S
import Data.Sequence (Seq, (|>), (><))
import Data.Maybe
import GHC.Exts(toList)

-- | A handy miscellaneous function to linearly map over a range of numbers in a given number of steps
mapLinear :: (Double -> b) -> Double -> Double -> Double -> [b]
mapLinear f s e n = map (\v -> f $ s + (v * (e - s) / n)) [0..n]

-- $ Basics

-- | The wrapper type for a matplotlib computation.
data Matplotlib = Matplotlib {
  mpCommands :: Seq MplotCommand   -- ^ Resolved computations that have been transformed to commands
  , mpPendingOption :: Maybe ([Option] -> MplotCommand)   -- ^ A pending computation that is affected by applied options
  , mpRest :: Seq MplotCommand  -- ^ Computations that follow the one that is pending
  }

-- | A maplotlib command, right now we have a very shallow embedding essentially
-- dealing in strings containing python code as well as the ability to load
-- data. The loaded data should be a json object.
data MplotCommand
  = LoadData B.ByteString
  | Exec { es :: String }
  deriving (Show, Eq, Ord)

-- | Throughout the API we need to accept options in order to expose
-- matplotlib's many configuration options.
data Option =
  -- | results in a=b
  K String String
  -- | just inserts the option verbatim as an argument at the end of the function
  | P String
  deriving (Show, Eq, Ord)

-- | Convert an 'MplotCommand' to python code, doesn't do much right now
toPy :: MplotCommand -> String
toPy (LoadData _) = error "withMplot needed to load data"
toPy (Exec str)   = str

-- | Resolve the pending command with no options provided.
resolvePending :: Matplotlib -> Matplotlib
resolvePending m = m { mpCommands =
                       (maybe (mpCommands m)
                              (\pendingCommand -> (mpCommands m |> pendingCommand []))
                              $ mpPendingOption m) >< mpRest m
                     , mpPendingOption = Nothing
                     , mpRest = S.empty}

-- | The io action is given a list of python commands to execute (note that
-- these are commands in the sense of lines of python code; each inidivudal line
-- may not be parseable on its own
withMplot :: Matplotlib -> ([String] -> IO a) -> IO a
withMplot m f = preload cs []
  where
    cs = toList $ mpCommands $ resolvePending m
    preload [] cmds = f $ map toPy $ reverse cmds
    preload ((LoadData obj):l) cmds =
          withSystemTempFile "data.json"
            (\dataFile dataHandle -> do
                B.hPutStr dataHandle obj
                hClose dataHandle
                preload l $ ((map Exec $ pyReadData dataFile) ++ cmds))
    preload (c:l) cmds = preload l (c:cmds)

-- | Create a plot that executes the string as python code
mplotString :: String -> Matplotlib
mplotString s = Matplotlib S.empty Nothing (S.singleton $ Exec s)

-- | Create an empty plot. This the beginning of most plotting commands.
mp :: Matplotlib
mp = Matplotlib S.empty Nothing S.empty

-- | Load the given data into the 'data' array
readData :: ToJSON a => a -> Matplotlib
readData d = Matplotlib (S.singleton $ LoadData $ encode d) Nothing S.empty

infixl 5 %
-- | Combine two matplotlib commands
(%) :: Matplotlib -> Matplotlib -> Matplotlib
a % b | isJust $ mpPendingOption b = b { mpCommands = mpCommands (resolvePending a) >< mpCommands b }
      | otherwise = a { mpRest = mpRest a >< mpCommands b >< mpRest b }

infixl 6 #
-- | Add Python code to the last matplotlib command
(#) :: (MplotValue val) => Matplotlib -> val -> Matplotlib
m # v | S.null $ mpRest m =
        case mpPendingOption m of
          Nothing -> m { mpRest = S.singleton $ Exec $ toPython v }
          (Just f) -> m { mpPendingOption = Just (\o -> Exec $ es (f o) ++ toPython v)}
      | otherwise = m { mpRest = S.adjust (\(Exec s) -> Exec $ s ++ toPython v) (S.length (mpRest m) - 1) (mpRest m) }

-- | Values which can be combined together to form a matplotlib command. These
-- specify how values are rendered in Python code.
class MplotValue val where
  toPython :: val -> String

instance MplotValue String where
  toPython s = s
instance MplotValue [String] where
  toPython [] = ""
  toPython (x:xs) = toPython x ++ "," ++ toPython xs
instance MplotValue Double where
  toPython s = show s
instance MplotValue Integer where
  toPython s = show s
instance MplotValue Int where
  toPython s = show s
instance MplotValue Bool where
  toPython s = show s
instance (MplotValue x) => MplotValue (x, x) where
  toPython (n, v) = toPython n ++ " = " ++ toPython v
instance (MplotValue (x, y)) => MplotValue [(x, y)] where
  toPython [] = ""
  toPython (x:xs) = toPython x ++ ", " ++ toPython xs

default (Integer, Int, Double)

-- $ Options

-- | Add an option to the last matplotlib command. Commands can have only one option!
-- optFn :: Matplotlib -> Matplotlib
optFn :: ([Option] -> String) -> Matplotlib -> Matplotlib
optFn f l | isJust $ mpPendingOption l = error "Commands can have only open option. TODO Enforce this through the type system or relax it!"
          | otherwise = l' { mpPendingOption = Just (\os -> Exec (sl `combine` f os)) }
  where (l', (Exec sl)) = removeLast l
        removeLast x@(Matplotlib _ Nothing s) = (x { mpRest = sdeleteAt (S.length s - 1) s }
                                                , fromMaybe (Exec "") (slookup (S.length s - 1) s))
        removeLast _ = error "TODO complex options"
        -- TODO When containers is >0.5.8 replace these
        slookup i s | i < S.length s = Just $ S.index s i
                    | otherwise      = Nothing
        sdeleteAt i s | i < S.length s = S.take i s >< S.drop (i + 1) s
                      | otherwise      = s
        combine [] r = r
        combine l [] = l
        combine l r | [last l] == "(" && [head r] == "," = l ++ tail r
                    | otherwise = l ++ r

-- | Merge two commands with options between
options :: Matplotlib -> Matplotlib
options l = optFn (\o -> renderOptions o) l

infixl 6 ##
-- | A combinator like '#' that also inserts an option
(##) :: MplotValue val => Matplotlib -> val -> Matplotlib
m ## v = options m # v

-- | An internal helper to convert a list of options to the python code that
-- applies those options in a call.
renderOptions :: [Option] -> [Char]
renderOptions [] = ""
renderOptions xs = f xs
  where  f (P a:l) = "," ++ toPython a ++ f l
         f (K a b:l) = "," ++ toPython a ++  "=" ++ toPython b ++ f l
         f [] = ""

-- | An internal helper that modifies the options of a plot.
optionFn :: ([Option] -> [Option]) -> Matplotlib -> Matplotlib
optionFn f m = case mpPendingOption m of
                 (Just cmd) -> m { mpPendingOption = Just (\os -> cmd $ f os) }
                 Nothing -> error "Can't apply an option to a non-option command"

-- | Apply a list of options to a plot resolving any pending options.
option :: Matplotlib -> [Option] -> Matplotlib
option m os = resolvePending $ optionFn (\os' -> os ++ os') m

infixl 6 @@
-- | A combinator for 'option' that applies a list of options to a plot
(@@) :: Matplotlib -> [Option] -> Matplotlib
m @@ os = option m os

-- | Bind a list of default options to a plot. Positional options are kept in
-- order and default that way as well. Keyword arguments are
def :: Matplotlib -> [Option] -> Matplotlib
def m os = optionFn (defFn os) m

defFn :: [Option] -> [Option] -> [Option]
defFn os os' = merge ps' ps ++ (nub $ ks' ++ ks)
           where isK (K _ _) = True
                 isK _ = False
                 isP (P _) = True
                 isP _ = False
                 ps  = filter isP os
                 ps' = filter isP os'
                 ks  = filter isK os
                 ks' = filter isK os'
                 merge l []  = l
                 merge [] l' = l'
                 merge (x:l) (_:l') = (x : merge l l')

-- $ Python operations

-- | Run python given a code string.
python :: Foldable t => t String -> IO (Either String String)
python codeStr =
  catch (withSystemTempFile "code.py"
         (\codeFile codeHandle -> do
             forM_ codeStr (hPutStrLn codeHandle)
             hClose codeHandle
             Right <$> readProcess "/usr/bin/python3" [codeFile] ""))
         (\e -> return $ Left $ show (e :: IOException))

-- | The standard python includes of every plot
pyIncludes :: [[Char]]
pyIncludes = ["import matplotlib"
             -- TODO Provide a way to set the render backend
             -- ,"matplotlib.use('GtkAgg')"
             ,"import matplotlib.path as mpath"
             ,"import matplotlib.patches as mpatches"
             ,"import matplotlib.pyplot as plot"
             ,"import matplotlib.mlab as mlab"
             ,"import matplotlib.colors as mcolors"
             ,"import matplotlib.collections as mcollections"
             ,"from matplotlib import cm"
             ,"from mpl_toolkits.mplot3d import axes3d"
             ,"import numpy as np"
             ,"import os"
             ,"import sys"
             ,"import json"
             ,"import random, datetime"
             ,"from matplotlib.dates import DateFormatter, WeekdayLocator"
             ,"ax = plot.figure().gca()"
             ,"axes = [plot.figure().gca()]"]

-- | The python command that reads external data into the python data array
pyReadData :: [Char] -> [[Char]]
pyReadData filename = ["data = json.loads(open('" ++ filename ++ "').read())"]

-- | Detach python so we don't block (TODO This isn't working reliably)
pyDetach :: [[Char]]
pyDetach = ["pid = os.fork()"
           ,"if(pid != 0):"
           ,"  exit(0)"]

-- | Python code to show a plot
pyOnscreen :: [[Char]]
pyOnscreen = ["plot.draw()"
             ,"plot.show()"]

-- | Python code that saves a figure
pyFigure :: [Char] -> [[Char]]
pyFigure output = ["plot.savefig('" ++ output ++ "')"]

-- | Create a positional option
o1 x = P x

-- | Create a keyword option
o2 x y = K x y