{-# LANGUAGE
OverloadedStrings,
OverloadedLists,
NoImplicitPrelude
  #-}


module Main where


-- General
import BasePrelude
-- Testing
import Test.Hspec
-- Text
import Data.Text (Text)
import qualified Data.Text as T
-- Bob-specific
import Bob


main :: IO ()
main = do
  (_, _, mbErrors) <- readData
  hspec $ do
    parsingTests
    searchTests
    behaviorTests
    matcherTests
    generatorTests
    warningTests
    specify "rules are loaded without warnings" $
      unless (null mbErrors) $
        expectationFailure (unlines mbErrors)

parsingTests :: Spec
parsingTests = context "parsing:" $ do
  specify "parse the simplest rule" $ do
    rules <- testReadRules "a = 1: b\n"
    rules `shouldBe` [Rule Nothing [("b", [("a", Top 1)])]]

  specify "parse 2 rules" $ do
    rules <- testReadRules $ T.unlines [
      "a = 1: b",
      "# whatever",
      "",
      "# whatever",
      "x = X: y" ]
    rules `shouldBe` [
      Rule Nothing [("b", [("a", Top 1)])],
      Rule Nothing [("y", [("x", Whatever)])]]

  specify "don't require newline at the end of file" $ do
    rules <- testReadRules "a = 1: b"
    rules `shouldBe` [
      Rule Nothing [("b", [("a", Top 1)])]]

  specify "accept an empty file" $ do
    rules <- testReadRules ""
    rules `shouldBe` []

  specify "accept a file with just a comment" $ do
    rules <- testReadRules "# comment"
    rules `shouldBe` []

  specify "priority can't be 0" $ do
    err <- testReadRulesButFail "a = 0: b"
    err `shouldBe` unlines [
      "line 1, column 6:",
      "expecting rest of integer",
      "priority can't be 0" ]

searchTests :: Spec
searchTests = context "search:" $ do
  specify "order entities with equal priority alphabetically" $ do
    rules <- testReadRules $ T.unlines [
      "e = 5: x",
      "b = 5: x",
      "c = 5: x",
      "",
      "#### hi",
      "d = 5: x",
      "a = 5: x" ]
    matchRules "x" rules `shouldBe` [
      ((Just "hi", "a"), Top 5),
      ((Nothing,   "b"), Top 5),
      ((Nothing,   "c"), Top 5),
      ((Just "hi", "d"), Top 5),
      ((Nothing,   "e"), Top 5)]

behaviorTests :: Spec
behaviorTests = context "behavior:" $ do
  specify "####-notes work" $ do
    rules <- testReadRules $ T.unlines [
      "####  blah",
      "a = 1: b" ]
    rules `shouldBe` [
      Rule (Just "blah") [("b", [("a", Top 1)])]]

  specify "later priorities override earlier ones" $ do
    rules <- testReadRules $ T.unlines [
      "a = 1: one two",
      "    2: two" ]
    rules `shouldBe` [
      Rule Nothing [
        ("one", [("a", Top 1)]),
        ("two", [("a", Top 2)])]]

  specify "a matcher can generate several entities for a pattern" $ do
    rules <- testReadRules $ T.unlines [
      "zip Aa",
      "    Xx",
      "    2: {(A a) ()}" ]
    rules `shouldBe` [
      Rule Nothing [
        ("AA",[("X",Top 2)]),
        ("Aa",[("X",Top 2),("x",Top 2)]),
        ("aA",[("X",Top 2),("x",Top 2)]),
        ("aa",[("x",Top 2)])]]

matcherTests :: Spec
matcherTests = context "matchers:" $ do
  specify "zip" $ do
    rules <- testReadRules $ T.unlines [
      "zip ab",
      "    AB",
      "    1: ()+",
      "    2: +()" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a+",[("A",Top 1)]),
        ("b+",[("B",Top 1)]),
        ("+a",[("A",Top 2)]),
        ("+b",[("B",Top 2)])]]

  specify "many-to-one" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: a",
      "    2: b" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a",[("x",Top 1)]),
        ("b",[("x",Top 2)])]]

  specify "order" $ do
    rules <- testReadRules $ T.unlines [
      "(x y) : a b" ]
    rules `shouldBe` [
      Rule Nothing [
        ("x", [("a",Top 1), ("b",Top 2)]),
        ("y", [("a",Top 1), ("b",Top 2)])]]

generatorTests :: Spec
generatorTests = context "generators:" $ do
  specify "row of generators" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: a (b c)" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a",[("x",Top 1)]),
        ("b",[("x",Top 1)]),
        ("c",[("x",Top 1)])]]

  specify "sequence" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: +(a b){c d}-" ]
    rules `shouldBe` [
      Rule Nothing [
        ("+acd-",[("x",Top 1)]),
        ("+adc-",[("x",Top 1)]),
        ("+bcd-",[("x",Top 1)]),
        ("+bdc-",[("x",Top 1)])]]

  specify "literal" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: a 'bcd' '''' '()'" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a"  ,[("x",Top 1)]),
        ("bcd",[("x",Top 1)]),
        ("'"  ,[("x",Top 1)]),
        ("()" ,[("x",Top 1)])]]

  specify "single generator" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: (x y)" ]
    rules `shouldBe` [
      Rule Nothing [
        ("x",[("x",Top 1)]),
        ("y",[("x",Top 1)])]]

  specify "variable" $ do
    rules <- testReadRules $ T.unlines [
      "zip a",
      "    A",
      "    1: ()" ]
    rules `shouldBe` [
      Rule Nothing [("a",[("A",Top 1)])]]

  specify "any-of" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: (a b)" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a",[("x",Top 1)]),
        ("b",[("x",Top 1)])]]

  specify "permutation" $ do
    rules <- testReadRules $ T.unlines [
      "x = 1: {a b}" ]
    rules `shouldBe` [
      Rule Nothing [
        ("ab",[("x",Top 1)]),
        ("ba",[("x",Top 1)])]]

  specify "reference" $ do
    rules <- testReadRules $ T.unlines [
      "a = 1: a b",
      "",
      "x = 1: `a``'a'`" ]
    rules `shouldBe` [
      Rule Nothing [
        ("a",[("a",Top 1)]),
        ("b",[("a",Top 1)])],
      Rule Nothing [
        ("aa",[("x",Top 1)]),
        ("ab",[("x",Top 1)]),
        ("ba",[("x",Top 1)]),
        ("bb",[("x",Top 1)])]]

warningTests :: Spec
warningTests = context "warnings:" $ do
  specify "arguments of 'zip' have unequal lengths" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "zip abc",
      "    wxyz",
      "    1: ()" ]
    warnings `shouldBe` unlines [
      "warnings in rule at line 1, column 1:",
      "  lengths of zipped rows don't match" ]

  specify "an undefined thing is referenced" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "a   : 1 2 3",
      "`e` : x y z" ]
    warnings `shouldBe` unlines [
      "warnings in rule at line 1, column 1:",
      "  ‘e’ was referenced but wasn't defined yet" ]

  specify "no value can be provided for a variable" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "a  : 1 2 3",
      "() : x y z" ]
    warnings `shouldBe` unlines [
      "warnings in rule at line 1, column 1:",
      "  there's a variable in the rule but no value provided for it" ]

  specify "an empty pattern is encountered" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "a  : 1 2 3",
      "'' : x y z" ]
    warnings `shouldBe` unlines [
      "warnings in rule at line 1, column 1:",
      "  matcher #2 contains an empty pattern" ]

  specify "priorities aren't satisfied" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "e1 = 1: x",
      "     2: y",
      "e2 = 1: x",
      "     2: y",
      "e3 = 2: x",
      "     1: y" ]
    warnings `shouldBe` unlines [
      "‘x’ finds:",
      "  2 entities with priority 1 or less: e1 e2",
      "  3 entities with priority 2 or less: e1 e2 e3",
      "",
      "‘y’ finds:",
      "  3 entities with priority 2 or less: e3 e1 e2" ]

  specify "an entity can't be found using only ASCII" $ do
    (_, warnings) <- testReadRulesAndWarnings $ T.unlines [
      "bad1 = 1: x€y",     -- bad (non-ASCII)
      "bad2 = 1: ä",       -- bad (non-ASCII too)
      "okay1 = 1: ₮ ***",  -- okay (there's a good pattern available)
      "okay2 = 1: ₹",      -- okay (there's a good pattern in another rule)
      "",
      "okay2 = 1: rupee" ]
    warnings `shouldBe` unlines [
      "‘bad1’ can't be found with ASCII; found by: x€y",
      "",
      "‘bad2’ can't be found with ASCII; found by: ä" ]

testReadRules :: Text -> IO [Rule]
testReadRules rulesString =
  case readRuleFile rulesString of
    Left err -> do
      expectationFailure (show err)
      error "test failed"
    Right (rules, []) ->
      return rules
    Right (_rules, warnings) -> do
      expectationFailure (unparagraphs warnings)
      error "test failed"

testReadRulesButFail :: Text -> IO String
testReadRulesButFail rulesString =
  case readRuleFile rulesString of
    Left err ->
      -- Errors don't have “\n” at the end but we often compare them
      -- against something generated with 'unlines', and 'unlines'
      -- always adds a newline, so let's add a newline too.
      return (show err ++ "\n")
    Right _ -> do
      expectationFailure "there was no error"
      error "test failed"

testReadRulesAndWarnings :: Text -> IO ([Rule], String)
testReadRulesAndWarnings rulesString =
  case readRuleFile rulesString of
    Left err -> do
      expectationFailure (show err)
      error "test failed"
    Right (rules, warnings) ->
      return (rules, unparagraphs warnings)

-- | Separate paragraphs with blank lines.
unparagraphs :: [String] -> String
unparagraphs =
  intercalate "\n" . map (++ "\n") .
  map (dropWhile (== '\n')) . map (dropWhileEnd (== '\n'))
