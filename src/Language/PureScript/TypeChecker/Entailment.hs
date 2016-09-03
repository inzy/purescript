{-# LANGUAGE NamedFieldPuns #-}

-- |
-- Type class entailment
--
module Language.PureScript.TypeChecker.Entailment
  ( InstanceContext
  , replaceTypeClassDictionaries
  ) where

import Prelude.Compat

import Control.Arrow (second)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.State
import Control.Monad.Supply.Class (MonadSupply(..))
import Control.Monad.Writer

import Data.Foldable (fold, for_)
import Data.Function (on)
import Data.Functor (($>))
import Data.List (minimumBy, nub)
import Data.Maybe (fromMaybe, isJust, maybeToList, mapMaybe)
import qualified Data.Map as M
import qualified Data.Set as S

import Language.PureScript.AST
import Language.PureScript.Crash
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.TypeChecker.Monad
import Language.PureScript.TypeChecker.Unify
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Types
import qualified Language.PureScript.Constants as C

-- | The 'InstanceContext' tracks those constraints which can be satisfied.
type InstanceContext = M.Map (Maybe ModuleName)
                         (M.Map (Qualified (ProperName 'ClassName))
                           (M.Map (Qualified Ident)
                             TypeClassDictionaryInScope))

-- | A type substitution which makes an instance head match a list of types.
--
-- Note: we store many types per type variable name. For any name, all types
-- should unify if we are going to commit to an instance.
type Matching a = M.Map String a

-- | Merge two type class contexts
combineContexts :: InstanceContext -> InstanceContext -> InstanceContext
combineContexts = M.unionWith (M.unionWith M.union)

-- | Replace type class dictionary placeholders with inferred type class dictionaries
replaceTypeClassDictionaries
  :: forall m
   . (MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => Bool
  -> Expr
  -> m (Expr, [(Ident, Constraint)])
replaceTypeClassDictionaries shouldGeneralize expr = do
    -- Loop, deferring any unsolved constraints, until there are no more
    -- constraints which can be solved, then make a generalization pass.
    let loop e = do
          (e', solved) <- deferPass e
          if getAny solved
            then loop e'
            else return e'
    loop expr >>= generalizePass
  where
    -- This pass solves constraints where possible, deferring constraints if not.
    deferPass :: Expr -> m (Expr, Any)
    deferPass = fmap (second fst) . runWriterT . flip evalStateT M.empty . f where
      f :: Expr -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
      (_, f, _) = everywhereOnValuesTopDownM return (go True) return

    -- This pass generalizes any remaining constraints
    generalizePass :: Expr -> m (Expr, [(Ident, Constraint)])
    generalizePass = fmap (second snd) . runWriterT . flip evalStateT M.empty . f where
      f :: Expr -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
      (_, f, _) = everywhereOnValuesTopDownM return (go False) return

    go :: Bool -> Expr -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
    go deferErrors dict@(TypeClassDictionary _ _ hints) =
      rethrow (addHints hints) $ entails shouldGeneralize deferErrors dict
    go _ other = return other

-- | Three options for how we can handle a constraint, depending on the mode we're in.
data EntailsResult a
  = Solved a TypeClassDictionaryInScope
  -- ^ We solved this constraint
  | Unsolved Constraint
  -- ^ We couldn't solve this constraint right now, it will be generalized
  | Deferred
  -- ^ We couldn't solve this constraint right now, so it has been deferred

-- |
-- Check that the current set of type class dictionaries entail the specified type class goal, and, if so,
-- return a type class dictionary reference.
--
entails
  :: forall m
   . (MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => Bool
  -> Bool
  -> Expr
  -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
entails shouldGeneralize deferErrors (TypeClassDictionary constraint context hints) =
    solve constraint
  where
    forClassName :: InstanceContext -> Qualified (ProperName 'ClassName) -> [Type] -> [TypeClassDictionaryInScope]
    forClassName ctx cn@(Qualified (Just mn) _) tys = concatMap (findDicts ctx cn) (nub (Nothing : Just mn : map Just (mapMaybe ctorModules tys)))
    forClassName _ _ _ = internalError "forClassName: expected qualified class name"

    ctorModules :: Type -> Maybe ModuleName
    ctorModules (TypeConstructor (Qualified (Just mn) _)) = Just mn
    ctorModules (TypeConstructor (Qualified Nothing _)) = internalError "ctorModules: unqualified type name"
    ctorModules (TypeApp ty _) = ctorModules ty
    ctorModules _ = Nothing

    findDicts :: InstanceContext -> Qualified (ProperName 'ClassName) -> Maybe ModuleName -> [TypeClassDictionaryInScope]
    findDicts ctx cn = maybe [] M.elems . (>>= M.lookup cn) . flip M.lookup ctx

    valUndefined :: Expr
    valUndefined = Var (Qualified (Just (ModuleName [ProperName C.prim])) (Ident C.undefined))

    solve :: Constraint -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
    solve con = go 0 con
      where
        go :: Int -> Constraint -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) Expr
        go work (Constraint className' tys' _) | work > 1000 = throwError . errorMessage $ PossiblyInfiniteInstance className' tys'
        go work con'@(Constraint className' tys' conInfo) = StateT . (withErrorMessageHint (ErrorSolvingConstraint con') .) . runStateT $ do
            -- We might have unified types by solving other constraints, so we need to
            -- apply the latest substitution.
            latestSubst <- lift (gets checkSubstitution)
            let tys'' = map (substituteType latestSubst) tys'
            -- Get the inferred constraint context so far, and merge it with the global context
            inferred <- get
            -- We need information about functional dependencies, so we have to look up the class
            -- name in the environment:
            let findClass = fromMaybe (internalError "entails: type class not found in environment") . M.lookup className'
            TypeClassData{ typeClassDependencies } <- lift (gets (findClass . typeClasses . checkEnv))
            let instances =
                  [ (substs, tcd)
                  | tcd <- forClassName (combineContexts context inferred) className' tys''
                    -- Make sure the type unifies with the type in the type instance definition
                  , substs <- maybeToList (matches typeClassDependencies tcd tys'')
                  ]
            solution <- lift . lift $ unique instances
            case solution of
              Solved substs tcd -> do
                -- Note that we solved something.
                tell (Any True, mempty)
                -- Make sure the substitution is valid:
                lift . for_ substs $ pairwiseM unifyTypes
                -- Now enforce any functional dependencies, using unification
                -- Note: we need to generate fresh types for any unconstrained
                -- type variables before unifying.
                let subst = fmap head substs
                currentSubst <- lift (gets checkSubstitution)
                subst' <- lift . lift $ withFreshTypes tcd (fmap (substituteType currentSubst) subst)
                lift $ zipWithM_ (\t1 t2 -> do
                  let inferredType = replaceAllTypeVars (M.toList subst') t1
                  unifyTypes inferredType t2) (tcdInstanceTypes tcd) tys''
                currentSubst' <- lift (gets checkSubstitution)
                let subst'' = fmap (substituteType currentSubst') subst'
                -- Solve any necessary subgoals
                args <- solveSubgoals subst'' (tcdDependencies tcd)
                let match = foldr (\(superclassName, index) dict -> subclassDictionaryValue dict superclassName index)
                                  (mkDictionary (tcdName tcd) args)
                                  (tcdPath tcd)
                return match
              Unsolved unsolved@(Constraint unsolvedClassName@(Qualified _ pn) unsolvedTys _) -> do
                -- Generate a fresh name for the unsolved constraint's new dictionary
                ident <- freshIdent ("dict" ++ runProperName pn)
                let qident = Qualified Nothing ident
                -- Store the new dictionary in the InstanceContext so that we can solve this goal in
                -- future.
                let newDict = TypeClassDictionaryInScope qident [] unsolvedClassName unsolvedTys Nothing
                    newContext = M.singleton Nothing (M.singleton unsolvedClassName (M.singleton qident newDict))
                modify (combineContexts newContext)
                -- Mark this constraint for generalization
                tell (mempty, [(ident, unsolved)])
                return (Var qident)
              Deferred ->
                -- Constraint was deferred, just return the dictionary unchanged,
                -- with no unsolved constraints. Hopefully, we can solve this later.
                return (TypeClassDictionary (Constraint className' tys'' conInfo) context hints)
          where
            -- | When checking functional dependencies, we need to use unification to make
            -- sure it is safe to use the selected instance. We will unify the solved type with
            -- the type in the instance head under the substition inferred from its instantiation.
            -- As an example, when solving MonadState t0 (State Int), we choose the
            -- MonadState s (State s) instance, and we unify t0 with Int, since the functional
            -- dependency from MonadState dictates that t0 should unify with s\[s -> Int], which is
            -- Int. This is fine, but in some cases, the substitution does not remove all TypeVars
            -- from the type, so we end up with a unification error. So, any type arguments which
            -- appear in the instance head, but not in the substitution need to be replaced with
            -- fresh type variables. This function extends a substitution with fresh type variables
            -- as necessary, based on the types in the instance head.
            withFreshTypes
              :: TypeClassDictionaryInScope
              -> Matching Type
              -> m (Matching Type)
            withFreshTypes TypeClassDictionaryInScope{..} subst = do
                let onType = everythingOnTypes S.union fromTypeVar
                    typeVarsInHead = foldMap onType tcdInstanceTypes
                                  <> foldMap (foldMap (foldMap onType . constraintArgs)) tcdDependencies
                    typeVarsInSubst = S.fromList (M.keys subst)
                    uninstantiatedTypeVars = typeVarsInHead S.\\ typeVarsInSubst
                newSubst <- traverse withFreshType (S.toList uninstantiatedTypeVars)
                return (subst <> M.fromList newSubst)
              where
                fromTypeVar (TypeVar v) = S.singleton v
                fromTypeVar _ = S.empty

                withFreshType s = do
                  t <- freshType
                  return (s, t)

            unique :: [(a, TypeClassDictionaryInScope)] -> m (EntailsResult a)
            unique [] | deferErrors = return Deferred
                      -- We need a special case for nullary type classes, since we want
                      -- to generalize over Partial constraints.
                      | shouldGeneralize && (null tys' || any canBeGeneralized tys') = return (Unsolved con')
                      | otherwise = throwError . errorMessage $ NoInstanceFound con'
            unique [(a, dict)] = return $ Solved a dict
            unique tcds | pairwiseAny overlapping (map snd tcds) = do
                            tell . errorMessage $ OverlappingInstances className' tys' (map (tcdName . snd) tcds)
                            return $ uncurry Solved (head tcds)
                        | otherwise = return $ uncurry Solved (minimumBy (compare `on` length . tcdPath . snd) tcds)

            canBeGeneralized :: Type -> Bool
            canBeGeneralized TUnknown{} = True
            canBeGeneralized Skolem{} = True
            canBeGeneralized _ = False

            -- |
            -- Check if two dictionaries are overlapping
            --
            -- Dictionaries which are subclass dictionaries cannot overlap, since otherwise the overlap would have
            -- been caught when constructing superclass dictionaries.
            overlapping :: TypeClassDictionaryInScope -> TypeClassDictionaryInScope -> Bool
            overlapping TypeClassDictionaryInScope{ tcdPath = _ : _ } _ = False
            overlapping _ TypeClassDictionaryInScope{ tcdPath = _ : _ } = False
            overlapping TypeClassDictionaryInScope{ tcdDependencies = Nothing } _ = False
            overlapping _ TypeClassDictionaryInScope{ tcdDependencies = Nothing } = False
            overlapping tcd1 tcd2 = tcdName tcd1 /= tcdName tcd2

            -- Create dictionaries for subgoals which still need to be solved by calling go recursively
            -- E.g. the goal (Show a, Show b) => Show (Either a b) can be satisfied if the current type
            -- unifies with Either a b, and we can satisfy the subgoals Show a and Show b recursively.
            solveSubgoals :: Matching Type -> Maybe [Constraint] -> StateT InstanceContext (WriterT (Any, [(Ident, Constraint)]) m) (Maybe [Expr])
            solveSubgoals _ Nothing = return Nothing
            solveSubgoals subst (Just subgoals) =
              Just <$> traverse (go (work + 1) . mapConstraintArgs (map (replaceAllTypeVars (M.toList subst)))) subgoals

            -- Make a dictionary from subgoal dictionaries by applying the correct function
            mkDictionary :: Qualified Ident -> Maybe [Expr] -> Expr
            mkDictionary fnName Nothing = Var fnName
            mkDictionary fnName (Just []) = Var fnName
            mkDictionary fnName (Just dicts) = foldl App (Var fnName) dicts

        -- Turn a DictionaryValue into a Expr
        subclassDictionaryValue :: Expr -> Qualified (ProperName a) -> Integer -> Expr
        subclassDictionaryValue dict superclassName index =
          App (Accessor (C.__superclass_ ++ showQualified runProperName superclassName ++ "_" ++ show index)
                        dict)
              valUndefined
entails _ _ _ = internalError "entails: expected TypeClassDictionary"

-- Check if an instance matches our list of types, allowing for types
-- to be solved via functional dependencies. If the types match, we return a
-- substitution which makes them match. If not, we return 'Nothing'.
matches :: [FunctionalDependency] -> TypeClassDictionaryInScope -> [Type] -> Maybe (Matching [Type])
matches deps TypeClassDictionaryInScope{..} tys = do
    -- First, find those types which match exactly
    let matched = zipWith typeHeadsAreEqual tys tcdInstanceTypes
    -- Now, use any functional dependencies to infer any remaining types
    substs <- covers matched
    -- Verify that any repeated type variables are unifiable
    verifySubstitution (M.unionsWith (++) substs)
  where
    -- | Find the closure of a set of functional dependencies.
    covers :: Monoid subst => [Maybe subst] -> Maybe [subst]
    covers ms = guard covered $> map fold ms
      where
        covered :: Bool
        covered = finalSet == S.fromList [0..length ms - 1]

        initialSet :: S.Set Int
        initialSet = S.fromList . map snd . filter (isJust . fst) $ zip ms [0..]

        finalSet :: S.Set Int
        finalSet = untilFixedPoint applyAll initialSet

        untilFixedPoint :: Eq a => (a -> a) -> a -> a
        untilFixedPoint f = go
          where
          go a | a' == a = a'
               | otherwise = go a'
            where a' = f a

        applyAll :: S.Set Int -> S.Set Int
        applyAll s = foldr applyDependency s deps

        applyDependency :: FunctionalDependency -> S.Set Int -> S.Set Int
        applyDependency FunctionalDependency{..} xs
          | S.fromList fdDeterminers `S.isSubsetOf` xs = xs <> S.fromList fdDetermined
          | otherwise = xs

    --
    -- Check whether the type heads of two types are equal (for the purposes of type class dictionary lookup),
    -- and return a substitution from type variables to types which makes the type heads unify.
    --
    typeHeadsAreEqual :: Type -> Type -> Maybe (Matching [Type])
    typeHeadsAreEqual (TUnknown u1)        (TUnknown u2)        | u1 == u2 = Just M.empty
    typeHeadsAreEqual (Skolem _ s1 _ _)    (Skolem _ s2 _ _)    | s1 == s2 = Just M.empty
    typeHeadsAreEqual t                    (TypeVar v)                     = Just (M.singleton v [t])
    typeHeadsAreEqual (TypeConstructor c1) (TypeConstructor c2) | c1 == c2 = Just M.empty
    typeHeadsAreEqual (TypeLevelString s1) (TypeLevelString s2) | s1 == s2 = Just M.empty
    typeHeadsAreEqual (TypeApp h1 t1)      (TypeApp h2 t2)                 = M.unionWith (++) <$> typeHeadsAreEqual h1 h2
                                                                                              <*> typeHeadsAreEqual t1 t2
    typeHeadsAreEqual REmpty REmpty = Just M.empty
    typeHeadsAreEqual r1@RCons{} r2@RCons{} =
        M.unionWith (++) <$> foldMap (uncurry typeHeadsAreEqual) int
                         <*> go sd1 r1' sd2 r2'
      where
        (s1, r1') = rowToList r1
        (s2, r2') = rowToList r2

        int = [ (t1, t2) | (name, t1) <- s1, (name', t2) <- s2, name == name' ]
        sd1 = [ (name, t1) | (name, t1) <- s1, name `notElem` map fst s2 ]
        sd2 = [ (name, t2) | (name, t2) <- s2, name `notElem` map fst s1 ]

        go :: [(String, Type)] -> Type -> [(String, Type)] -> Type -> Maybe (Matching [Type])
        go [] REmpty             [] REmpty             = Just M.empty
        go [] (TUnknown u1)      [] (TUnknown u2)      | u1 == u2 = Just M.empty
        go [] (TypeVar v1)       [] (TypeVar v2)       | v1 == v2 = Just M.empty
        go [] (Skolem _ sk1 _ _) [] (Skolem _ sk2 _ _) | sk1 == sk2 = Just M.empty
        go sd r                  [] (TypeVar v)        = Just (M.singleton v [rowFromList (sd, r)])
        go _  _                  _  _                  = Nothing
    typeHeadsAreEqual _ _ = Nothing

    -- Ensure that a substitution is valid
    verifySubstitution :: Matching [Type] -> Maybe (Matching [Type])
    verifySubstitution = traverse meet where
      meet ts | pairwiseAll unifiesWith ts = Just ts
              | otherwise = Nothing

      unifiesWith :: Type -> Type -> Bool
      unifiesWith (TUnknown _)         _                    = True
      unifiesWith _                    (TUnknown _)         = True
      unifiesWith (Skolem _ s1 _ _)    (Skolem _ s2 _ _)    = s1 == s2
      unifiesWith (TypeVar v1)         (TypeVar v2)         = v1 == v2
      unifiesWith (TypeLevelString s1) (TypeLevelString s2) = s1 == s2
      unifiesWith (TypeConstructor c1) (TypeConstructor c2) = c1 == c2
      unifiesWith (TypeApp h1 t1)      (TypeApp h2 t2)      = h1 `unifiesWith` h2 && t1 `unifiesWith` t2
      unifiesWith REmpty               REmpty               = True
      unifiesWith r1@RCons{}           r2@RCons{} =
          let (s1, r1') = rowToList r1
              (s2, r2') = rowToList r2

              int = [ (t1, t2) | (name, t1) <- s1, (name', t2) <- s2, name == name' ]
              sd1 = [ (name, t1) | (name, t1) <- s1, name `notElem` map fst s2 ]
              sd2 = [ (name, t2) | (name, t2) <- s2, name `notElem` map fst s1 ]
          in all (uncurry unifiesWith) int && go sd1 r1' sd2 r2'
        where
          go :: [(String, Type)] -> Type -> [(String, Type)] -> Type -> Bool
          go _  (TUnknown _)      _  _                 = True
          go _  _                 _  (TUnknown _)      = True
          go [] (Skolem _ s1 _ _) [] (Skolem _ s2 _ _) = s1 == s2
          go [] REmpty            [] REmpty            = True
          go [] (TypeVar v1)      [] (TypeVar v2)      = v1 == v2
          go _  _                 _  _                 = False
      unifiesWith _ _ = False

-- | Check all pairs of values in a list match a predicate
pairwiseAll :: (a -> a -> Bool) -> [a] -> Bool
pairwiseAll _ [] = True
pairwiseAll _ [_] = True
pairwiseAll p (x : xs) = all (p x) xs && pairwiseAll p xs

-- | Check any pair of values in a list match a predicate
pairwiseAny :: (a -> a -> Bool) -> [a] -> Bool
pairwiseAny _ [] = True
pairwiseAny _ [_] = True
pairwiseAny p (x : xs) = any (p x) xs || pairwiseAny p xs

pairwiseM :: Applicative m => (a -> a -> m ()) -> [a] -> m ()
pairwiseM _ [] = pure ()
pairwiseM _ [_] = pure ()
pairwiseM p (x : xs) = traverse (p x) xs *> pairwiseM p xs
