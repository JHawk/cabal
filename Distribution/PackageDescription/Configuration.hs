{-# OPTIONS -cpp #-}
-- OPTIONS required for ghc-6.4.x compat, and must appear first
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -cpp #-}
{-# OPTIONS_NHC98 -cpp #-}
{-# OPTIONS_JHC -fcpp #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Configuration
-- Copyright   :  Thomas Schilling, 2007
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Configurations

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.PackageDescription.Configuration (
    finalizePackageDescription,
    flattenPackageDescription,

    -- Utils
    parseCondition,
    freeVars,
  ) where

import Distribution.Package (Package, Dependency(..))
import Distribution.PackageDescription
         ( GenericPackageDescription(..), PackageDescription(..)
         , Library(..), Executable(..), BuildInfo(..)
         , Flag(..), FlagName(..), FlagAssignment
         , CondTree(..), ConfVar(..), Condition(..) )
import Distribution.Simple.PackageIndex (PackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Version
         ( VersionRange(..), withinRange )
import Distribution.Compiler
         ( CompilerId(CompilerId) )
import Distribution.System
         ( OS, Arch )
import Distribution.Simple.Utils (currentDir, lowercase)

import Distribution.Text
         ( Text(parse) )
import Distribution.Compat.ReadP as ReadP hiding ( char )
import qualified Distribution.Compat.ReadP as ReadP ( char )

import Data.Char ( isAlphaNum )
import Data.Maybe ( catMaybes, maybeToList )
import Data.List  ( nub )
import Data.Map ( Map, fromListWith, toList )
import qualified Data.Map as M
import Data.Monoid

#if defined(__GLASGOW_HASKELL__) && (__GLASGOW_HASKELL__ < 606)
import qualified Text.Read as R
import qualified Text.Read.Lex as L
#endif

------------------------------------------------------------------------------

-- | Simplify the condition and return its free variables.
simplifyCondition :: Condition c
                  -> (c -> Either d Bool)   -- ^ (partial) variable assignment
                  -> (Condition d, [d])
simplifyCondition cond i = fv . walk $ cond
  where
    walk cnd = case cnd of
      Var v   -> either Var Lit (i v)
      Lit b   -> Lit b
      CNot c  -> case walk c of
                   Lit True -> Lit False
                   Lit False -> Lit True
                   c' -> CNot c'
      COr c d -> case (walk c, walk d) of
                   (Lit False, d') -> d'
                   (Lit True, _)   -> Lit True
                   (c', Lit False) -> c'
                   (_, Lit True)   -> Lit True
                   (c',d')         -> COr c' d'
      CAnd c d -> case (walk c, walk d) of
                    (Lit False, _) -> Lit False
                    (Lit True, d') -> d'
                    (_, Lit False) -> Lit False
                    (c', Lit True) -> c'
                    (c',d')        -> CAnd c' d'
    -- gather free vars
    fv c = (c, fv' c)
    fv' c = case c of
      Var v     -> [v]
      Lit _      -> []
      CNot c'    -> fv' c'
      COr c1 c2  -> fv' c1 ++ fv' c2
      CAnd c1 c2 -> fv' c1 ++ fv' c2

-- | Simplify a configuration condition using the os and arch names.  Returns
--   the names of all the flags occurring in the condition.
simplifyWithSysParams :: OS -> Arch -> CompilerId -> Condition ConfVar
                      -> (Condition FlagName, [FlagName])
simplifyWithSysParams os arch (CompilerId comp compVer) cond = (cond', flags)
  where
    (cond', flags) = simplifyCondition cond interp
    interp (OS os')    = Right $ os' == os
    interp (Arch arch') = Right $ arch' == arch
    interp (Impl comp' vr) = Right $ comp' == comp
                                  && compVer `withinRange` vr
    interp (Flag  f)   = Left f

-- XXX: Add instances and check
--
-- prop_sC_idempotent cond a o = cond' == cond''
--   where
--     cond'  = simplifyCondition cond a o
--     cond'' = simplifyCondition cond' a o
--
-- prop_sC_noLits cond a o = isLit res || not (hasLits res)
--   where
--     res = simplifyCondition cond a o
--     hasLits (Lit _) = True
--     hasLits (CNot c) = hasLits c
--     hasLits (COr l r) = hasLits l || hasLits r
--     hasLits (CAnd l r) = hasLits l || hasLits r
--     hasLits _ = False
--

-- | Parse a configuration condition from a string.
parseCondition :: ReadP r (Condition ConfVar)
parseCondition = condOr
  where
    condOr   = sepBy1 condAnd (oper "||") >>= return . foldl1 COr
    condAnd  = sepBy1 cond (oper "&&")>>= return . foldl1 CAnd
    cond     = sp >> (boolLiteral +++ inparens condOr +++ notCond +++ osCond
                      +++ archCond +++ flagCond +++ implCond )
    inparens   = between (ReadP.char '(' >> sp) (sp >> ReadP.char ')' >> sp)
    notCond  = ReadP.char '!' >> sp >> cond >>= return . CNot
    osCond   = string "os" >> sp >> inparens osIdent >>= return . Var
    archCond = string "arch" >> sp >> inparens archIdent >>= return . Var
    flagCond = string "flag" >> sp >> inparens flagIdent >>= return . Var
    implCond = string "impl" >> sp >> inparens implIdent >>= return . Var
    boolLiteral   = fmap Lit  parse
    archIdent     = fmap Arch parse
    osIdent       = fmap OS   parse
    flagIdent     = fmap (Flag . FlagName . lowercase) (munch1 isIdentChar)
    isIdentChar c = isAlphaNum c || c == '_' || c == '-'
    oper s        = sp >> string s >> sp
    sp            = skipSpaces
    implIdent     = do i <- parse
                       vr <- sp >> option AnyVersion parse
                       return $ Impl i vr

------------------------------------------------------------------------------

mapCondTree :: (a -> b) -> (c -> d) -> (Condition v -> Condition w) 
            -> CondTree v c a -> CondTree w d b
mapCondTree fa fc fcnd (CondNode a c ifs) =
    CondNode (fa a) (fc c) (map g ifs)
  where
    g (cnd, t, me) = (fcnd cnd, mapCondTree fa fc fcnd t,
                           fmap (mapCondTree fa fc fcnd) me)

mapTreeConstrs :: (c -> d) -> CondTree v c a -> CondTree v d a
mapTreeConstrs f = mapCondTree id f id

mapTreeConds :: (Condition v -> Condition w) -> CondTree v c a -> CondTree w c a
mapTreeConds f = mapCondTree id id f

mapTreeData :: (a -> b) -> CondTree v c a -> CondTree v c b
mapTreeData f = mapCondTree f id id

-- | Result of dependency test. Isomorphic to @Maybe d@ but renamed for
--   clarity.
data DepTestRslt d = DepOk | MissingDeps d 

instance Monoid d => Monoid (DepTestRslt d) where
    mempty = DepOk
    mappend DepOk x = x
    mappend x DepOk = x
    mappend (MissingDeps d) (MissingDeps d') = MissingDeps (d `mappend` d')


data BT a = BTN a | BTB (BT a) (BT a)  -- very simple binary tree


-- | Try to find a flag assignment that satisfies the constaints of all trees.
--
-- Returns either the missing dependencies, or a tuple containing the
-- resulting data, the associated dependencies, and the chosen flag
-- assignments.
--
-- In case of failure, the _smallest_ number of of missing dependencies is
-- returned. [XXX: Could also be specified with a function argument.]
--
-- XXX: The current algorithm is rather naive.  A better approach would be to:
--
-- * Rule out possible paths, by taking a look at the associated dependencies.
--
-- * Infer the required values for the conditions of these paths, and
--   calculate the required domains for the variables used in these
--   conditions.  Then picking a flag assignment would be linear (I guess).
--
-- This would require some sort of SAT solving, though, thus it's not
-- implemented unless we really need it.
--   
resolveWithFlags :: Monoid a =>
     [(FlagName,[Bool])]
        -- ^ Domain for each flag name, will be tested in order.
  -> OS      -- ^ OS as returned by Distribution.System.buildOS
  -> Arch    -- ^ Arch as returned by Distribution.System.buildArch
  -> CompilerId -- ^ Compiler flavour + version
  -> [Dependency]  -- ^ Additional constraints
  -> [CondTree ConfVar [Dependency] a]    
  -> ([Dependency] -> DepTestRslt [Dependency])  -- ^ Dependency test function.
  -> Either [Dependency] -- missing dependencies
       ([a], [Dependency], FlagAssignment)
       -- ^ In the returned dependencies, there will be no duplicates by name
resolveWithFlags dom os arch impl constrs trees checkDeps =
    case try dom [] of
      Right r -> Right r
      Left dbt -> Left $ findShortest dbt
  where 
    extraConstrs = toDepMap constrs
 
    -- simplify trees by (partially) evaluating all conditions and converting
    -- dependencies to dependency maps.
    simplifiedTrees = map ( mapTreeConstrs toDepMap  -- convert to maps
                          . mapTreeConds (fst . simplifyWithSysParams os arch impl))
                          trees

    -- version to combine dependencies where the result will only contain keys
    -- from the left (first) map.  If a key also exists in the right map, both
    -- constraints will be intersected.
    leftJoin :: DependencyMap -> DependencyMap -> DependencyMap
    leftJoin left extra =
        DependencyMap $
          M.foldWithKey tightenConstraint (unDependencyMap left)
                                          (unDependencyMap extra)
      where tightenConstraint n c l =
                case M.lookup n l of
                  Nothing -> l
                  Just vr -> M.insert n (IntersectVersionRanges vr c) l

    -- @try@ recursively tries all possible flag assignments in the domain and
    -- either succeeds or returns a binary tree with the missing dependencies
    -- encountered in each run.  Since the tree is constructed lazily, we
    -- avoid some computation overhead in the successful case.
    try [] flags = 
        let (depss, as) = unzip 
                         . map (simplifyCondTree (env flags)) 
                         $ simplifiedTrees
            deps = fromDepMap $ leftJoin (mconcat depss)
                                         extraConstrs
        in case (checkDeps deps, deps) of
             (DepOk, ds) -> Right (as, ds, flags)
             (MissingDeps mds, _) -> Left (BTN mds)
    try ((n, vals):rest) flags = 
        tryAll $ map (\v -> try rest ((n, v):flags)) vals

    tryAll = foldr mp mz

    -- special version of `mplus' for our local purposes
    mp (Left xs)   (Left ys)   = (Left (BTB xs ys))
    mp (Left _)    m@(Right _) = m
    mp m@(Right _) _           = m

    -- `mzero'
    mz = Left (BTN [])

    env flags flag = (maybe (Left flag) Right . lookup flag) flags

    -- for the error case we inspect our lazy tree of missing dependencies and
    -- pick the shortest list of missing dependencies
    findShortest (BTN x) = x
    findShortest (BTB lt rt) = 
        let l = findShortest lt
            r = findShortest rt
        in case (l,r) of
             ([], xs) -> xs  -- [] is too short
             (xs, []) -> xs
             ([x], _) -> [x] -- single elem is optimum
             (_, [x]) -> [x]
             (xs, ys) -> if lazyLengthCmp xs ys
                         then xs else ys 
    -- lazy variant of @\xs ys -> length xs <= length ys@
    lazyLengthCmp [] _ = True
    lazyLengthCmp _ [] = False
    lazyLengthCmp (_:xs) (_:ys) = lazyLengthCmp xs ys

-- | A map of dependencies.  Newtyped since the default monoid instance is not
--   appropriate.  The monoid instance uses 'IntersectVersionRanges'.
newtype DependencyMap = DependencyMap { unDependencyMap :: Map String VersionRange }
#if !defined(__GLASGOW_HASKELL__) || (__GLASGOW_HASKELL__ >= 606)
  deriving (Show, Read)
#else
-- The Show/Read instance for Data.Map in ghc-6.4 is useless
-- so we have to re-implement it here:
instance Show DependencyMap where
  showsPrec d (DependencyMap m) =
      showParen (d > 10) (showString "DependencyMap" . shows (M.toList m))

instance Read DependencyMap where
  readPrec = parens $ R.prec 10 $ do
    R.Ident "DependencyMap" <- R.lexP
    xs <- R.readPrec
    return (DependencyMap (M.fromList xs))
      where parens :: R.ReadPrec a -> R.ReadPrec a
            parens p = optional
             where
               optional  = p R.+++ mandatory
               mandatory = paren optional

            paren :: R.ReadPrec a -> R.ReadPrec a
            paren p = do L.Punc "(" <- R.lexP
                         x          <- R.reset p
                         L.Punc ")" <- R.lexP
                         return x

  readListPrec = R.readListPrecDefault
#endif

instance Monoid DependencyMap where
    mempty = DependencyMap M.empty
    (DependencyMap a) `mappend` (DependencyMap b) = 
        DependencyMap (M.unionWith IntersectVersionRanges a b)

toDepMap :: [Dependency] -> DependencyMap
toDepMap ds = 
  DependencyMap $ fromListWith IntersectVersionRanges [ (p,vr) | Dependency p vr <- ds ]

fromDepMap :: DependencyMap -> [Dependency]
fromDepMap m = [ Dependency p vr | (p,vr) <- toList (unDependencyMap m) ]

simplifyCondTree :: (Monoid a, Monoid d) =>
                    (v -> Either v Bool) 
                 -> CondTree v d a 
                 -> (d, a)
simplifyCondTree env (CondNode a d ifs) =
    foldr mappend (d, a) $ catMaybes $ map simplifyIf ifs
  where
    simplifyIf (cnd, t, me) = 
        case simplifyCondition cnd env of
          (Lit True, _) -> Just $ simplifyCondTree env t
          (Lit False, _) -> fmap (simplifyCondTree env) me
          _ -> error $ "Environment not defined for all free vars" 

-- | Flatten a CondTree.  This will resolve the CondTree by taking all
--  possible paths into account.  Note that since branches represent exclusive
--  choices this may not result in a \"sane\" result.
ignoreConditions :: (Monoid a, Monoid c) => CondTree v c a -> (a, c)
ignoreConditions (CondNode a c ifs) = (a, c) `mappend` mconcat (concatMap f ifs)
  where f (_, t, me) = ignoreConditions t 
                       : maybeToList (fmap ignoreConditions me)

freeVars :: CondTree ConfVar c a  -> [FlagName]
freeVars t = [ f | Flag f <- freeVars' t ]
  where
    freeVars' (CondNode _ _ ifs) = concatMap compfv ifs
    compfv (c, ct, mct) = condfv c ++ freeVars' ct ++ maybe [] freeVars' mct
    condfv c = case c of
      Var v      -> [v]
      Lit _      -> []
      CNot c'    -> condfv c'
      COr c1 c2  -> condfv c1 ++ condfv c2
      CAnd c1 c2 -> condfv c1 ++ condfv c2

------------------------------------------------------------------------------
-- Convert GenericPackageDescription to PackageDescription
--

data PDTagged = Lib Library | Exe String Executable | PDNull deriving Show

instance Monoid PDTagged where
    mempty = PDNull
    PDNull `mappend` x = x
    x `mappend` PDNull = x
    Lib l `mappend` Lib l' = Lib (l `mappend` l')
    Exe n e `mappend` Exe n' e' | n == n' = Exe n (e `mappend` e')
    _ `mappend` _ = bug "Cannot combine incompatible tags"

-- | Create a package description with all configurations resolved.
--
-- This function takes a `GenericPackageDescription` and several environment
-- parameters and tries to generate `PackageDescription` by finding a flag
-- assignment that result in satisfiable dependencies.
--
-- It takes as inputs a not necessarily complete specifications of flags
-- assignments, an optional package index as well as platform parameters.  If
-- some flags are not assigned explicitly, this function will try to pick an
-- assignment that causes this function to succeed.  The package index is
-- optional since on some platforms we cannot determine which packages have
-- been installed before.  When no package index is supplied, every dependency
-- is assumed to be satisfiable, therefore all not explicitly assigned flags
-- will get their default values.
--
-- This function will fail if it cannot find a flag assignment that leads to
-- satisfiable dependencies.  (It will not try alternative assignments for
-- explicitly specified flags.)  In case of failure it will return a /minimum/
-- number of dependencies that could not be satisfied.  On success, it will
-- return the package description and the full flag assignment chosen.
-- 
finalizePackageDescription ::
     Package pkg
  => FlagAssignment  -- ^ Explicitly specified flag assignments
  -> Maybe (PackageIndex pkg) -- ^ Available dependencies. Pass 'Nothing' if
                              -- this is unknown.
  -> OS     -- ^ OS-name
  -> Arch   -- ^ Arch-name
  -> CompilerId -- ^ Compiler + Version
  -> [Dependency]  -- ^ Additional constraints
  -> GenericPackageDescription
  -> Either [Dependency]
            (PackageDescription, FlagAssignment)
	     -- ^ Either missing dependencies or the resolved package
	     -- description along with the flag assignments chosen.
finalizePackageDescription userflags mpkgs os arch impl constraints
        (GenericPackageDescription pkg flags mlib0 exes0) =
    case resolveFlags of
      Right ((mlib, exes'), deps, flagVals) ->
        Right ( pkg { library = mlib
                    , executables = exes'
                    , buildDepends = nub deps
                    }
              , flagVals )
      Left missing -> Left $ nub missing
  where
    -- Combine lib and exes into one list of @CondTree@s with tagged data
    condTrees = maybeToList (fmap (mapTreeData Lib) mlib0 )
                ++ map (\(name,tree) -> mapTreeData (Exe name) tree) exes0

    untagRslts = foldr untag (Nothing, [])
      where
        untag (Lib _) (Just _, _) = bug "Only one library expected"
        untag (Lib l) (Nothing, exes) = (Just l, exes)
        untag (Exe n e) (mlib, exes)
         | any ((== n) . fst) exes = bug "Exe with same name found"
         | otherwise = (mlib, exes ++ [(n, e)])
        untag PDNull x = x  -- actually this should not happen, but let's be liberal

    resolveFlags =
        case resolveWithFlags flagChoices os arch impl constraints condTrees check of
          Right (as, ds, fs) ->
              let (mlib, exes) = untagRslts as in
              Right ( (fmap libFillInDefaults mlib,
                       map (\(n,e) -> (exeFillInDefaults e) { exeName = n }) exes),
                     ds, fs)
          Left missing      -> Left missing

    flagChoices  = map (\(MkFlag n _ d) -> (n, d2c n d)) flags
    d2c n b      = maybe [b, not b] (\x -> [x]) $ lookup n userflags
    --flagDefaults = map (\(n,x:_) -> (n,x)) flagChoices
    check ds     = if all satisfyDep ds
                   then DepOk
                   else MissingDeps $ filter (not . satisfyDep) ds
    -- if we don't know which packages are present, we just accept any
    -- dependency
    satisfyDep   = maybe (const True)
                         (\pkgs -> not . null . PackageIndex.lookupDependency pkgs)
                         mpkgs

{-
let tst_p = (CondNode [1::Int] [Distribution.Package.Dependency "a" AnyVersion] [])
let tst_p2 = (CondNode [1::Int] [Distribution.Package.Dependency "a" (EarlierVersion (Version [1,0] [])), Distribution.Package.Dependency "a" (LaterVersion (Version [2,0] []))] [])

let p_index = Distribution.Simple.PackageIndex.fromList [Distribution.Package.PackageIdentifier "a" (Version [0,5] []), Distribution.Package.PackageIdentifier "a" (Version [2,5] [])]
let look = not . null . Distribution.Simple.PackageIndex.lookupDependency p_index
let looks ds = mconcat $ map (\d -> if look d then DepOk else MissingDeps [d]) ds
resolveWithFlags [] Distribution.System.Linux Distribution.System.I386 (Distribution.Compiler.GHC,Version [6,8,2] []) [tst_p] looks   ===>  Right ...
resolveWithFlags [] Distribution.System.Linux Distribution.System.I386 (Distribution.Compiler.GHC,Version [6,8,2] []) [tst_p2] looks  ===>  Left ...
-}

-- | Flatten a generic package description by ignoring all conditions and just
-- join the field descriptors into on package description.  Note, however,
-- that this may lead to inconsistent field values, since all values are
-- joined into one field, which may not be possible in the original package
-- description, due to the use of exclusive choices (if ... else ...).
--
-- XXX: One particularly tricky case is defaulting.  In the original package
-- description, e.g., the source directory might either be the default or a
-- certain, explicitly set path.  Since defaults are filled in only after the
-- package has been resolved and when no explicit value has been set, the
-- default path will be missing from the package description returned by this
-- function.
flattenPackageDescription :: GenericPackageDescription -> PackageDescription
flattenPackageDescription (GenericPackageDescription pkg _ mlib0 exes0) =
    pkg { library = mlib
        , executables = reverse exes
        , buildDepends = nub $ ldeps ++ reverse edeps
        }
  where
    (mlib, ldeps) = case mlib0 of
        Just lib -> let (l,ds) = ignoreConditions lib in
                    (Just (libFillInDefaults l), ds)
        Nothing -> (Nothing, [])
    (exes, edeps) = foldr flattenExe ([],[]) exes0
    flattenExe (n, t) (es, ds) =
        let (e, ds') = ignoreConditions t in
        ( (exeFillInDefaults $ e { exeName = n }) : es, ds' ++ ds )

-- This is in fact rather a hack.  The original version just overrode the
-- default values, however, when adding conditions we had to switch to a
-- modifier-based approach.  There, nothing is ever overwritten, but only
-- joined together.
--
-- This is the cleanest way i could think of, that doesn't require
-- changing all field parsing functions to return modifiers instead.
libFillInDefaults :: Library -> Library
libFillInDefaults lib@(Library { libBuildInfo = bi }) =
    lib { libBuildInfo = biFillInDefaults bi }

exeFillInDefaults :: Executable -> Executable
exeFillInDefaults exe@(Executable { buildInfo = bi }) =
    exe { buildInfo = biFillInDefaults bi }

biFillInDefaults :: BuildInfo -> BuildInfo
biFillInDefaults bi =
    if null (hsSourceDirs bi)
    then bi { hsSourceDirs = [currentDir] }
    else bi

bug :: String -> a
bug msg = error $ msg ++ ". Consider this a bug."