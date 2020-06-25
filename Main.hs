module Dlam (main) where

import Language.Dlam.Interpreter (formatError)
import Language.Dlam.TypeChecking.Monad
  ( runNewCheckerWithOpts
  , tcrLog
  , tcrRes
  , Verbosity
  , verbositySilent
  , verbosityDebug
  , verbosityInfo
  , TCLog
  , formatLog
  )
import qualified Language.Dlam.Interpreter as Interpreter
import Language.Dlam.Util.Pretty
  ( RenderOptions(..)
  , defaultRenderOptions
  , pprintShowWithOpts
  , green, red
  )

import Control.Monad      (replicateM)
import Data.List          (isPrefixOf, partition, intercalate)
import System.Directory   (doesPathExist)
import System.Environment (getArgs)
import System.Exit
import qualified System.Clock as Clock
import Text.Printf

data Options = Options
  { verbosity :: Verbosity
  , renderOpts :: RenderOptions
  , tycOptimise :: Bool
  , benchmark   :: Bool
  , trials      :: Int
  }


defaultOptions :: Options
defaultOptions = Options
  { verbosity = verbosityInfo
  , renderOpts = defaultRenderOptions
  , tycOptimise = False
  , benchmark   = False
  , trials      = 1
  }


printLog :: RenderOptions -> Verbosity -> TCLog -> IO ()
printLog ro v l = putStrLn $ pprintShowWithOpts ro (formatLog v l)


parseArgs :: [String] -> IO (Options, [String])
parseArgs args = do
  let (optionArgs, nonOptionArgs) = partition ("--" `isPrefixOf`) args
  opts <- parseArgsWithDefaults defaultOptions optionArgs
  pure (opts, nonOptionArgs)
  where parseArgsWithDefaults opts [] = pure opts
        parseArgsWithDefaults opts ("--tyc-optimise":xs) =
          parseArgsWithDefaults (opts { tycOptimise = True }) xs
        parseArgsWithDefaults opts ("--benchmark":xs) =
          parseArgsWithDefaults (opts { benchmark = True }) xs
        parseArgsWithDefaults opts (x:xs) | "--trials=" `isPrefixOf` x =
          parseArgsWithDefaults (opts { trials = read (drop 9 x) }) xs
        parseArgsWithDefaults opts ("--silent":xs) =
          parseArgsWithDefaults (opts { verbosity = verbositySilent }) xs
        parseArgsWithDefaults opts ("--info":xs) =
          parseArgsWithDefaults (opts { verbosity = verbosityInfo }) xs
        parseArgsWithDefaults opts ("--debug":xs) =
          parseArgsWithDefaults (opts { verbosity = verbosityDebug, renderOpts = (renderOpts opts) { showIdentNumbers = True } }) xs
        parseArgsWithDefaults _ (x:_) = do
          putStrLn $ "unknown option: " <> x
          exitFailure


main :: IO ()
main = do
  (opts, args) <- parseArgs =<< getArgs
  let rOpts   = renderOpts opts
      printLn = putStrLn . pprintShowWithOpts rOpts
  case args of
    [] -> putStrLn "Please supply a filename as a command line argument"
    (fname:_) -> do
      exists <- doesPathExist fname
      if not exists
        then putStrLn $ "File `" <> fname <> "` cannot be found."
        else do
          input <- readFile fname
          exitStatus <- benchmarkTime (benchmark opts) (trials opts) (\() -> do
            res <- runNewCheckerWithOpts (benchmark opts) (tycOptimise opts) (Interpreter.runTypeChecker fname input)
            printLog (renderOpts opts) (verbosity opts) (tcrLog res)
            case tcrRes res of
              Left err -> do
                printLn $ red "Ill-typed."
                return (Left err)
              Right _ -> do
                printLn $ green "Well typed."
                return $ Right ())
          case exitStatus of
            Left err -> printLn (formatError err) >> exitFailure
            Right () -> exitSuccess

-- Benchmarking helpers follow

benchmarkTime :: Bool -> Int -> (() -> IO a) -> IO a
benchmarkTime False _ m = m ()
benchmarkTime True  trials m = do
   measurements <- replicateM trials timingComp
   let result = head (map snd measurements)
   let runs = map fst measurements
   let totalTime = sum runs
   let meanTime = totalTime / fromIntegral trials
   let error    = stdError runs
   -- Output
   putStrLn $ "Timing for each run   = " <> intercalate ", " (map show runs)
   printf "Mean time of %d trials = %6.2f (%6.2f) ms\n" trials meanTime error
   return result
  where
    timingComp = do
      start  <- Clock.getTime Clock.Monotonic
      -- Run the computation
      result <- m ()
      -- Force the result (to WHNF)
      _ <- return $ result `seq` result
      end    <- Clock.getTime Clock.Monotonic
      let time = fromIntegral (Clock.toNanoSecs (Clock.diffTimeSpec end start)) / (10^(6 :: Integer)::Double)
      return (time, result)

-- Sample standard deviation
stdDeviation :: [Double] -> Double
stdDeviation xs = sqrt (divisor * (sum . map (\x -> (x - mean)**2) $ xs))
  where
   divisor = 1 / ((cast n) - 1)
   n = length xs
   mean = sum xs / (cast n)

cast :: Int -> Double
cast = fromInteger . toInteger

-- Sample standard error
stdError :: [Double] -> Double
stdError []  = 0
stdError [_] = 0
stdError xs  = (stdDeviation xs) / sqrt (cast n)
  where
    n = length xs
