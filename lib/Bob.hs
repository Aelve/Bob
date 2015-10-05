{-# LANGUAGE
RecordWildCards,
ScopedTypeVariables,
OverloadedStrings,
RankNTypes,
FlexibleContexts
  #-}

module Bob
(
  Pattern,
  Entity,
  RuleName,
  Rule(..),
  readRules,
  matchRules,
  matchAndSortRules,
)
where


-- General
import Data.Foldable
import Data.Traversable
import Data.Monoid
import Data.Maybe
import Control.Applicative
import Control.Monad
import Control.Arrow
import Numeric.Natural
-- Monads
import Control.Monad.Writer
-- Lenses
import Lens.Micro.GHC
-- Lists
import Data.List (permutations, union, inits)
-- Sorting
import Data.List (sortOn)
import GHC.Exts (groupWith)
-- Text
import Text.Printf
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text (Text)
import Data.Char
-- Parsing
import Text.Megaparsec
import Text.Megaparsec.Text
import Text.Megaparsec.Lexer
-- Containers
import qualified Data.Map as M
import Data.Map (Map)
-- Files
import System.FilePath
import System.Directory
-- Data files
import Paths_bob


-- | A thing that we use for search (like “->”).
type Pattern = Text

-- | A thing that we search for (like “→”).
type Entity = Text

{- |
How high should the entity be in the list of results when it's searched by some pattern? @Top 1@ means “best match”, @Top 2@ means “best match or second best match”, etc. 'Whatever' means that you don't care.
-}
data Priority = Top Natural | Whatever
  deriving (Show, Eq)

instance Ord Priority where
  compare Whatever Whatever = EQ
  compare Whatever (Top _)  = GT
  compare (Top _) Whatever  = LT
  compare (Top a) (Top b)   = compare a b

type RuleName = Text

-- | Entities corresponding to a pattern (like “->” leads to “→”). There can
-- be several entities corresponding to a pattern even inside a single rule.
type EntitiesMap = Map Pattern [(Entity, Priority)]

-- | All patterns that an entity corresponds to (like “→” leads to “->”, “>”).
type PatternsMap = Map Entity [(Pattern, Priority)]

toPatternsMap :: EntitiesMap -> PatternsMap
toPatternsMap m = M.fromListWith (++) $ do
  (pattern, entities) <- M.toList m
  (entity, priority) <- entities
  return (entity, [(pattern, priority)])

data Generator
  = Literal Pattern
  | AnyOf [Generator]
  | Sequence [Generator]
  | Permutation [Generator]
  | Reference Entity
  | Variable
  deriving (Show)

priorityP :: WarnParser Priority
priorityP = asum [
  Whatever <$ char 'X',
  do x <- integer
     when (x == 0) $
       fail "priority can't be 0"
     return (Top (fromInteger x))]

literalP :: WarnParser Pattern
literalP = T.pack <$> choice [
  some literalChar,
  singleQuotes (many quotedChar) ]
  where
    literalChar = satisfy $ \x ->
      or [isSymbol x, isPunctuation x, isAlphaNum x] &&
      x `notElem` ("\"'`()[]{}" :: String)
    quotedChar = choice [
      try (string "''") >> pure '\'',
      satisfy $ \x -> not $ or [isSpace x, x == '\''] ]

generatorP :: WarnParser Generator
generatorP = do
  let singleGenerator = choice [
        Literal <$> literalP,
        Variable <$ try (string "()"),
        AnyOf <$> parens (generatorP `sepBy1` someSpaces),
        Permutation <$> braces (generatorP `sepBy1` someSpaces),
        Reference <$> backticks literalP ]
  gens <- some singleGenerator
  return $ case gens of
    [gen] -> gen
    _     -> Sequence gens

type Generators = [(Generator, Priority)]

data Matcher
  = Zip [(Text, Text)] Generators
  | ManyToOne Generators Entity
  deriving (Show)

evalGenerator
  :: PatternsMap     -- ^ Already generated patterns (needed for 'Reference')
  -> Maybe Text      -- ^ Variable value (needed for 'Variable')
  -> Generator       -- ^ Generator to evaluate
  -> Warn [Pattern]
evalGenerator _   _ (Literal x) = return [x]
evalGenerator psm var (AnyOf gs) = concat <$> mapM (evalGenerator psm var) gs
evalGenerator psm var (Sequence gs) = do
  ps :: [[Pattern]] <- mapM (evalGenerator psm var) gs
  return $ do
    chosen :: [Pattern] <- sequence ps
    return (mconcat chosen)
evalGenerator psm var (Permutation gs) = do
  ps :: [[Pattern]] <- mapM (evalGenerator psm var) gs
  return $ do
    perm :: [[Pattern]] <- permutations ps
    chosen :: [Pattern] <- sequence perm
    return (mconcat chosen)
evalGenerator psm _ (Reference x) = case M.lookup x psm of
  Nothing -> do
    warn (printf "‘%s’ was referenced but wasn't defined yet" (T.unpack x))
    return []
  -- The entity should be included as its own pattern, hence “x :”.
  Just pats -> return (x : map fst pats)
evalGenerator _ var Variable = case var of
  Nothing -> do
    warn "there's a variable in the rule but no value provided for it"
    return []
  Just x -> return [x]

evalGenerators
  :: PatternsMap                 -- ^ Already generated patterns
  -> Maybe Text                  -- ^ Variable value
  -> Generators                  -- ^ Pairs of (generator, priority)
  -> Warn [(Pattern, Priority)]
evalGenerators psm var gens = do
  groups :: [([Pattern], Priority)] <- (each._1) (evalGenerator psm var) gens
  -- Now groups have to be expanded, and patterns from later groups should
  -- replace earlier patterns. See https://github.com/aelve/bob/issues/47.
  let pats :: [(Pattern, Priority)]
      pats = [(p, f) | (ps, f) <- groups, p <- ps]
  -- To leave only the last occurrence of each pattern it's enough to convert
  -- the list to a Map and back, because that's how Map's fromList works.
  return $ M.toList (M.fromList pats)

{-
Note that a matcher can generate several entities for the same pattern, and sometimes it's even desirable – e.g. here “uU” can mean both “Ŭ” and “ŭ”:

@
zip AaEeIiOoUu
    ĂăĔĕĬĭŎŏŬŭ
    7: {(U u) ()}
@
-}
evalMatcher
  :: PatternsMap        -- ^ Already generated patterns
  -> Matcher            -- ^ Matcher to evaluate
  -> Warn EntitiesMap
evalMatcher psm (Zip pairs gens) = do
  results <- for pairs $ \(a, b) -> do
    patterns <- evalGenerators psm (Just a) gens
    return [(pattern, (b, priority)) | (pattern, priority) <- patterns]
  return $ fromListAccum (concat results)
evalMatcher psm (ManyToOne gens entity) = do
  patterns <- evalGenerators psm Nothing gens
  return $ fromListAccum $ do
    (pattern, priority) <- patterns
    return (pattern, (entity, priority))

generatorLineP :: WarnParser (Generator, Priority)
generatorLineP = do
  priority <- priorityP <* char ':'
  someSpaces
  gens <- generatorP `sepBy1` someSpaces
  return (AnyOf gens, priority)

matcherP :: WarnParser Matcher
matcherP = choice [zipP, manyToOneP]
  where
    nextLine = try (newline >> someSpaces)
    zipP = do
      string "zip" <* someSpaces
      lineA <- (T.chunksOf 1 <$> literalP) <* nextLine
      lineB <- (T.chunksOf 1 <$> literalP) <* nextLine
      when (length lineA /= length lineB) $
        warn "lengths of zipped rows don't match"
      gens <- generatorLineP `sepBy1` nextLine
      return (Zip (zip lineA lineB) gens)
    manyToOneP = do
      x <- literalP <* someSpaces
      char '=' <* someSpaces
      gens <- generatorLineP `sepBy1` nextLine
      return (ManyToOne gens x)

data Rule = Rule {
  ruleName     :: RuleName,
  ruleEntities :: EntitiesMap }
  deriving (Show)

ruleP :: PatternsMap -> WarnParser Rule
ruleP scope = do
  name <- currentLine
  let header = printf "warnings in rule ‘%s’:" (T.unpack name)
  groupWarnings header $ do
    matchers <- matcherP `endBy1` newline
    -- Evaluate all matchers, combining generated patterns as we go along and
    -- passing them to each evaluator (so that references could be resolved).
    let go :: PatternsMap    -- ^ all entities in scope
           -> EntitiesMap    -- ^ all generated entities so far
           -> Int            -- ^ matcher number
           -> [Matcher]      -- ^ matchers left to process
           -> Warn EntitiesMap
        go _psm entitiesMap _ [] = return entitiesMap
        go  psm entitiesMap i (matcher:rest) = do
          entityMap <- evalMatcher psm matcher
          when ("" `M.member` entityMap) $
            warn $ printf "matcher #%d contains an empty pattern" i
          go (M.unionWith union psm (toPatternsMap entityMap))
             (M.unionWith union entityMap entitiesMap)
             (i+1) rest
    entitiesMap <- go scope mempty 1 matchers
    -- Return the rule.
    let rule = Rule {
          ruleName     = name,
          ruleEntities = entitiesMap }
    return rule

ruleFileP :: WarnParser [Rule]
ruleFileP = do
  rule1 <- ruleP mempty
  (rule1:) <$> go (toPatternsMap (ruleEntities rule1))
  where
    go psm = choice [
      -- Either there is a new rule...
      do some newline
         rule <- ruleP psm
         let psm' = psm <> toPatternsMap (ruleEntities rule)
         (rule:) <$> go psm',
      -- ...or there isn't.
      pure [] ]

{- |
This code checks whether all priorities are satisfied – that is, for each pattern and entity it checks whether the pattern finds the entity in top N matches (where N is entity's priority). It does so by enumerating all patterns, then taking all entities that some specific pattern finds, then ordering them in layers like this

  * “x”, “y” have priority <= 1
  * “x”, “y”, “m” have priority <= 4
  * “x”, “y”, “m”, “3”, “a” have priority <= 7

and finally outputting a warning for each layer that has more entities than its priority allows.
-}
checkPriorities :: [Rule] -> [String]
checkPriorities = mapMaybe checkPattern . allPatterns
  where
    -- Find all patterns and associated entities.
    allPatterns :: [Rule] -> [(Pattern, [(Entity, Priority)])]
    allPatterns = M.toList . M.unionsWith (++) . map ruleEntities
    -- Sort and group entities by priority.
    sortEntities :: [(Entity, Priority)] -> [([Entity], Priority)]
    sortEntities = map (map fst &&& snd.head) . groupWith snd
    -- Discard a group if its priority isn't 'Top'.
    isTopPriority :: ([Entity], Priority) -> Maybe ([Entity], Int)
    isTopPriority (x, Top n) = Just (x, fromIntegral n)
    isTopPriority _          = Nothing
    -- Include earlier groups into later groups:
    -- if 1st group has priority 2 (i.e. “should be in first 2 matches”)
    -- and 2nd group has priority 3 (“should be in first 3 matches”)
    -- then members of the 1st group should be added to the 2nd group as well
    layers :: [([Entity], Int)] -> [([Entity], Int)]
    layers = map (concatMap fst &&& snd.last) . drop 1 . inits
    -- Find out whether a group is a good on (i.e. if it has priority N, it
    -- should have not more than N members).
    isGood :: ([Entity], Int) -> Bool
    isGood (entities, priority) = length entities <= priority
    -- Put it all together (and print warnings).
    checkPattern :: (Pattern, [(Entity, Priority)]) -> Maybe String
    checkPattern (pattern, pairs)
      | null warnings = Nothing
      | otherwise     = Just (unlines (header : warnings))
      where
        warnings = map generateWarning .
                   filter (not . isGood) .
                   layers . mapMaybe isTopPriority . sortEntities
                     $ pairs
        header = printf "‘%s’ finds:" (T.unpack pattern)
        generateWarning (entities, priority) =
          printf "  %d entities with priority %d or less: %s"
                 (length entities) priority
                 (unwords (map prettyChar entities))

matchRule :: Pattern -> Rule -> [((RuleName, Entity), Priority)]
matchRule query Rule{..} = do
  (entity, priority) <- M.findWithDefault [] query ruleEntities
  return ((ruleName, entity), priority)

matchRules :: Pattern -> [Rule] -> [((RuleName, Entity), Priority)]
matchRules query = concatMap (matchRule query)

matchAndSortRules :: Pattern -> [Rule] -> [(RuleName, Entity)]
matchAndSortRules query =
  map fst . sortOn snd . concatMap (matchRule query)

-- | Returns rules and warnings\/parsing errors (if there were any).
readRules :: IO ([Rule], [String])
readRules = do
  dataDir <- getDataDir
  ruleFiles <- filter ((== ".rules") . takeExtensions) <$>
               getDirectoryContents (dataDir </> "rules")
  results <- for ruleFiles $ \ruleFile -> do
    let path = dataDir </> "rules" </> ruleFile
    res <- warnParse ruleFileP ruleFile <$> T.readFile path
    return $ case res of
      Left err -> ([], [show err])
      Right (rules, warnings) -> (rules, warnings)
  let rules  = concat (map fst results)
      errors = filter (not . null) (map snd results)
  -- The 'unlines' is here to group lines in -warning groups- together.
  return (rules, checkPriorities rules ++ map unlines errors)

currentLine :: WarnParser Text
currentLine = choice [
  eol >> pure "",
  do x  <- anyChar
     xs <- anyChar `manyTill` try (eof <|> void eol)
     pure (T.pack (x:xs)) ]

type Warn a = forall m. MonadWriter [String] m => m a

warn :: String -> Warn ()
warn s = tell [s]

type WarnParser a = WriterT [String] Parser a

groupWarnings :: String -> WarnParser a -> WarnParser a
groupWarnings title = censor $ \s ->
  if null s then [] else title : map ("  " ++) s

warnParse :: WarnParser a -> FilePath -> Text ->
             Either ParseError (a, [String])
warnParse = parse . runWriterT

parens, braces, singleQuotes, backticks
  :: WarnParser a -> WarnParser a
parens       = between (char '(')  (char ')')
braces       = between (char '{')  (char '}')
singleQuotes = between (char '\'') (char '\'')
backticks    = between (char '`')  (char '`')

someSpaces :: WarnParser ()
someSpaces = void (some (char ' '))

fromListAccum :: Ord a => [(a, b)] -> Map a [b]
fromListAccum = M.fromListWith (++) . over (each._2) (:[])

prettyChar :: Entity -> String
prettyChar x
  | T.all good x = T.unpack x
  | otherwise    = "‘" ++ T.unpack x ++ "’"
  where good c = isAlphaNum c || isSymbol c
