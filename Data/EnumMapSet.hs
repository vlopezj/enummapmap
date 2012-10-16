{-# LANGUAGE BangPatterns, CPP, MagicHash, TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.EnumMapSet
-- Copyright   :  (c) Daan Leijen 2002
--                (c) Andriy Palamarchuk 2008
--                (c) Matthew West 2012
-- License     :  BSD-style
-- Maintainer  :
-- Stability   :  experimental
-- Portability :  Uses GHC extensions
--
-- Based on Data.IntSet.
--
-----------------------------------------------------------------------------

module Data.EnumMapSet (
            EnumMapSet,
            K(..), (:&)(..),
            -- * Query
            null,
            size,
            member,
            -- * Construction
            empty,
            singleton,
            insert,
            delete,
            -- * Combine
            union,
            difference,
            intersection,
            -- * Map
            map,
            -- * Folds
            foldr,
            -- * Lists
            toList,
            fromList
) where

import           Prelude hiding (lookup,
                                 map,
                                 filter,
                                 foldr, foldl,
                                 null, init,
                                 head, tail)

import           Data.Bits
import qualified Data.List as List
import           GHC.Exts (Word(..), Int(..))
import           GHC.Prim (indexInt8OffAddr#)
#include "MachDeps.h"

import           Data.EnumMapMap.Base ((:&)(..), K(..),
                                       IsEmm,
                                       EnumMapMap,
                                       Prefix, Nat, Mask,
                                       branchMask, mask,
                                       intFromNat,
                                       shiftRL, shiftLL,
                                       nomatch, zero,
                                       shorter,
                                       foldlStrict)
import qualified Data.EnumMapMap.Base as EMM

type EnumMapSet k = EnumMapMap k ()

type BitMap = Word

-- This is used instead of @EMM k BitMap@ in order to unpack the 'BitMap' in
-- 'Tip'. Hopefully this will lead to much optimisation by GHC.
data EMS k = Bin {-# UNPACK #-} !Prefix {-# UNPACK #-} !Mask
                 !(EMS k) !(EMS k)
           | Tip {-# UNPACK #-} !Int {-# UNPACK #-} !BitMap
           | Nil
             deriving (Show)

instance (Enum k) => IsEmm (K k) where
    data EnumMapMap (K k) v = KSC (EMS k)

    emptySubTrees e@(KSC emm) =
        case emm of
          Nil -> False
          _   -> EMM.emptySubTrees_ e
    emptySubTrees_ (KSC emm) = go emm
        where
          go t = case t of
                   Bin _ _ l r -> go l || go r
                   Tip _ _     -> False
                   Nil         -> True

    removeEmpties = id

    unsafeJoinKey (KSC _) = undefined

    empty = KSC Nil

    null (KSC ems) = case ems of
                       Nil -> True
                       _   -> False

    size (KSC ems) = go ems
        where
          go (Bin _ _ l r) = go l + go r
          go (Tip _ bm)    = bitcount 0 bm
          go Nil           = 0

    member !(K key') (KSC ems) = key `seq` go ems
        where
          go (Bin p m l r)
              | nomatch key p m = False
              | zero key m      = go l
              | otherwise       = go r
          go (Tip y bm) = prefixOf key == y && bitmapOf key .&. bm /= 0
          go Nil = False
          key = fromEnum key'

    singleton (K key') _
        = key `seq` KSC $ Tip (prefixOf key) (bitmapOf key)
          where key = fromEnum key'

    insert (K key') _ (KSC ems)
        = key `seq` KSC $ insertBM (prefixOf key) (bitmapOf key) ems
          where key = fromEnum key'

    delete (K key') (KSC ems)
        = key `seq` KSC $ deleteBM (prefixOf key) (bitmapOf key) ems
          where key = fromEnum key'

    foldrWithKey f init (KSC ems)
        = case ems of Bin _ m l r | m < 0 -> go (go init l) r
                                  | otherwise -> go (go init r) l
                      _          -> go init ems
          where
            go init' Nil           = init'
            go init' (Tip kx bm)   = foldrBits kx f' init' bm
            go init' (Bin _ _ l r) = go (go init' r) l
            f' !k t = f (K $ toEnum k) undefined t

    union (KSC ems1) (KSC ems2) = KSC $ go ems1 ems2
        where
          go t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
              | shorter m1 m2  = union1
              | shorter m2 m1  = union2
              | p1 == p2       = Bin p1 m1 (go l1 l2) (go r1 r2)
              | otherwise      = join p1 t1 p2 t2
              where
                union1  | nomatch p2 p1 m1  = join p1 t1 p2 t2
                        | zero p2 m1        = Bin p1 m1 (go l1 t2) r1
                        | otherwise         = Bin p1 m1 l1 (go r1 t2)

                union2  | nomatch p1 p2 m2  = join p1 t1 p2 t2
                        | zero p1 m2        = Bin p2 m2 (go t1 l2) r2
                        | otherwise         = Bin p2 m2 l2 (go t1 r2)

          go t@(Bin _ _ _ _) (Tip kx bm) = insertBM kx bm t
          go t@(Bin _ _ _ _) Nil = t
          go (Tip kx bm) t = insertBM kx bm t
          go Nil t = t

    difference (KSC ems1) (KSC ems2) = KSC $ go ems1 ems2
        where
          go t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
              | shorter m1 m2  = difference1
              | shorter m2 m1  = difference2
              | p1 == p2       = bin p1 m1 (go l1 l2) (go r1 r2)
              | otherwise      = t1
              where
                difference1 | nomatch p2 p1 m1  = t1
                            | zero p2 m1        = bin p1 m1 (go l1 t2) r1
                            | otherwise         = bin p1 m1 l1 (go r1 t2)

                difference2 | nomatch p1 p2 m2  = t1
                            | zero p1 m2        = go t1 l2
                            | otherwise         = go t1 r2

          go t@(Bin _ _ _ _) (Tip kx bm) = deleteBM kx bm t
          go t@(Bin _ _ _ _) Nil = t

          go t1@(Tip kx bm) t2 = differenceTip t2
              where differenceTip (Bin p2 m2 l2 r2)
                        | nomatch kx p2 m2 = t1
                        | zero kx m2 = differenceTip l2
                        | otherwise = differenceTip r2
                    differenceTip (Tip kx2 bm2)
                        | kx == kx2 = tip kx (bm .&. complement bm2)
                        | otherwise = t1
                    differenceTip Nil = t1

          go Nil _ = Nil

    intersection (KSC ems1) (KSC ems2) = KSC $ go ems1 ems2
        where
          go t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
              | shorter m1 m2  = intersection1
              | shorter m2 m1  = intersection2
              | p1 == p2       = bin p1 m1 (go l1 l2) (go r1 r2)
              | otherwise      = Nil
              where
                intersection1 | nomatch p2 p1 m1  = Nil
                              | zero p2 m1        = go l1 t2
                              | otherwise         = go r1 t2

                intersection2 | nomatch p1 p2 m2  = Nil
                              | zero p1 m2        = go t1 l2
                              | otherwise         = go t1 r2

          go t1@(Bin _ _ _ _) (Tip kx2 bm2) = intersectBM t1
              where intersectBM (Bin p1 m1 l1 r1)
                        | nomatch kx2 p1 m1 = Nil
                        | zero kx2 m1       = intersectBM l1
                        | otherwise         = intersectBM r1
                    intersectBM (Tip kx1 bm1)
                        | kx1 == kx2 = tip kx1 (bm1 .&. bm2)
                        | otherwise = Nil
                    intersectBM Nil = Nil

          go (Bin _ _ _ _) Nil = Nil

          go (Tip kx1 bm1) t2 = intersectBM t2
              where intersectBM (Bin p2 m2 l2 r2)
                        | nomatch kx1 p2 m2 = Nil
                        | zero kx1 m2       = intersectBM l2
                        | otherwise         = intersectBM r2
                    intersectBM (Tip kx2 bm2)
                        | kx1 == kx2 = tip kx1 (bm1 .&. bm2)
                        | otherwise = Nil
                    intersectBM Nil = Nil

          go Nil _ = Nil

    equal (KSC ems1) (KSC ems2) = go ems1 ems2
        where
          go (Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
              = (m1 == m2) && (p1 == p2) && (go l1 l2) && (go r1 r2)
          go (Tip kx1 bm1) (Tip kx2 bm2)
              = kx1 == kx2 && bm1 == bm2
          go Nil Nil = True
          go _   _   = False

    nequal (KSC ems1) (KSC ems2) = go ems1 ems2
        where
          go (Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
              = (m1 /= m2) || (p1 /= p2) || (go l1 l2) || (go r1 r2)
          go (Tip kx1 bm1) (Tip kx2 bm2)
              = kx1 /= kx2 || bm1 /= bm2
          go Nil Nil = False
          go _   _   = True

    insertWith = undefined
    insertWithKey = undefined
    lookup = undefined
    alter = undefined
    foldr = undefined
    map = undefined
    mapWithKey = undefined
    unionWith = undefined
    unionWithKey = undefined
    differenceWith = undefined
    differenceWithKey = undefined
    intersectionWith = undefined
    intersectionWithKey = undefined
    fromList = undefined
    toList = undefined

{---------------------------------------------------------------------
  Exported API

  The Set API is somewhat different to the Map API so we define the following
  functions to call the IsEMM functions with the type of 'v' as (), hoping that
  GHC will inline away all the empty parameters.
---------------------------------------------------------------------}

null :: (IsEmm k) => EnumMapSet k -> Bool
null = EMM.null

size :: (IsEmm k) => EnumMapSet k -> Int
size = EMM.size

member ::(IsEmm k) => k -> EnumMapSet k -> Bool
member = EMM.member

empty :: (IsEmm k) => EnumMapSet k
empty = EMM.empty

singleton :: (IsEmm k) => k -> EnumMapSet k
singleton !key = EMM.singleton key ()

insert :: (IsEmm k) => k -> EnumMapSet k -> EnumMapSet k
insert !key = EMM.insert key ()

delete :: (IsEmm k) => k -> EnumMapSet k -> EnumMapSet k
delete = EMM.delete

-- This function has not been optimised in any way.
foldr :: (IsEmm k) => (k -> t -> t) -> t -> EnumMapSet k -> t
foldr f = EMM.foldrWithKey go
    where
      go k _ z = f k z

-- | @'map' f s@ is the set obtained by applying @f@ to each element of @s@.
--
-- It's worth noting that the size of the result may be smaller if,
-- for some @(x,y)@, @x \/= y && f x == f y@
map :: (IsEmm k1, IsEmm k2) =>
       (k1 -> k2) -> EnumMapSet k1 -> EnumMapSet k2
map f = fromList . List.map f . toList

union :: (IsEmm k) => EnumMapSet k -> EnumMapSet k -> EnumMapSet k
union = EMM.union

difference :: (IsEmm k) => EnumMapSet k -> EnumMapSet k -> EnumMapSet k
difference = EMM.difference

intersection :: (IsEmm k) => EnumMapSet k -> EnumMapSet k -> EnumMapSet k
intersection = EMM.intersection

{---------------------------------------------------------------------
  List
---------------------------------------------------------------------}

fromList :: IsEmm k => [k] -> EnumMapSet k
fromList xs
    = foldlStrict (\t x -> insert x t) empty xs

toList :: IsEmm k => EnumMapSet k -> [k]
toList = foldr (:) []

{---------------------------------------------------------------------
  Instances
---------------------------------------------------------------------}

{---------------------------------------------------------------------
  Helper functions
---------------------------------------------------------------------}

insertBM :: Prefix -> BitMap -> EMS k -> EMS k
insertBM !kx !bm t
    = case t of
    Bin p m l r
      | nomatch kx p m -> join kx (Tip kx bm) p t
      | zero kx m      -> Bin p m (insertBM kx bm l) r
      | otherwise      -> Bin p m l (insertBM kx bm r)
    Tip kx' bm'
      | kx' == kx -> Tip kx' (bm .|. bm')
      | otherwise -> join kx (Tip kx bm) kx' t
    Nil -> Tip kx bm

deleteBM :: Prefix -> BitMap -> EMS k -> EMS k
deleteBM !kx !bm t
  = case t of
      Bin p m l r
          | nomatch kx p m -> t
          | zero kx m      -> bin p m (deleteBM kx bm l) r
          | otherwise      -> bin p m l (deleteBM kx bm r)
      Tip kx' bm'
          | kx' == kx -> tip kx (bm' .&. complement bm)
          | otherwise -> t
      Nil -> Nil

join :: Prefix -> EMS k -> Prefix -> EMS k -> EMS k
join p1 t1 p2 t2
  | zero p1 m = Bin p m t1 t2
  | otherwise = Bin p m t2 t1
  where
    m = branchMask p1 p2
    p = mask p1 m
{-# INLINE join #-}

bin :: Prefix -> Mask -> EMS k -> EMS k -> EMS k
bin _ _ l Nil = l
bin _ _ Nil r = r
bin p m l r   = Bin p m l r
{-# INLINE bin #-}

{--------------------------------------------------------------------
  @tip@ assures that we never have empty bitmaps within a tree.
--------------------------------------------------------------------}
tip :: Prefix -> BitMap -> EMS k
tip _ 0 = Nil
tip kx bm = Tip kx bm
{-# INLINE tip #-}

{----------------------------------------------------------------------
  Functions that generate Prefix and BitMap of a Key or a Suffix.

  Commentary and credits can be found with the original code in
  Data/IntSet/Base.hs in 'containers 5.0'.
----------------------------------------------------------------------}

suffixBitMask :: Int
suffixBitMask = bitSize (undefined::Word) - 1
{-# INLINE suffixBitMask #-}

prefixBitMask :: Int
prefixBitMask = complement suffixBitMask
{-# INLINE prefixBitMask #-}

prefixOf :: Int -> Prefix
prefixOf x = x .&. prefixBitMask
{-# INLINE prefixOf #-}

suffixOf :: Int -> Int
suffixOf x = x .&. suffixBitMask
{-# INLINE suffixOf #-}

bitmapOfSuffix :: Int -> BitMap
bitmapOfSuffix s = 1 `shiftLL` s
{-# INLINE bitmapOfSuffix #-}

bitmapOf :: Int -> BitMap
bitmapOf x = bitmapOfSuffix (suffixOf x)
{-# INLINE bitmapOf #-}

bitcount :: Int -> Word -> Int
bitcount a0 x0 = go a0 x0
  where go a 0 = a
        go a x = go (a + 1) (x .&. (x-1))
{-# INLINE bitcount #-}

{----------------------------------------------------------------------
  Folds over a BitMap.

  Commentary and credits can be found with the original code in
  Data/IntSet/Base.hs in 'containers 5.0'.
----------------------------------------------------------------------}

foldrBits :: Int -> (Int -> a -> a) -> a -> Nat -> a

{-# INLINE foldrBits #-}

indexOfTheOnlyBit :: Nat -> Int
{-# INLINE indexOfTheOnlyBit #-}
indexOfTheOnlyBit bitmask =
  I# (lsbArray `indexInt8OffAddr#` unboxInt
                   (intFromNat ((bitmask * magic) `shiftRL` offset)))
  where unboxInt (I# i) = i
#if WORD_SIZE_IN_BITS==32
        magic = 0x077CB531
        offset = 27
        !lsbArray = "\0\1\28\2\29\14\24\3\30\22\20\15\25\17\4\8\31\27\13\23\21\19\16\7\26\12\18\6\11\5\10\9"#
#else
        magic = 0x07EDD5E59A4E28C2
        offset = 58
        !lsbArray = "\63\0\58\1\59\47\53\2\60\39\48\27\54\33\42\3\61\51\37\40\49\18\28\20\55\30\34\11\43\14\22\4\62\57\46\52\38\26\32\41\50\36\17\19\29\10\13\21\56\45\25\31\35\16\9\12\44\24\15\8\23\7\6\5"#
#endif
lowestBitMask :: Nat -> Nat
lowestBitMask x = x .&. negate x
{-# INLINE lowestBitMask #-}

revNat :: Nat -> Nat
#if WORD_SIZE_IN_BITS==32
revNat x1 = case ((x1 `shiftRL` 1) .&. 0x55555555) .|. ((x1 .&. 0x55555555) `shiftLL` 1) of
              x2 -> case ((x2 `shiftRL` 2) .&. 0x33333333) .|. ((x2 .&. 0x33333333) `shiftLL` 2) of
                 x3 -> case ((x3 `shiftRL` 4) .&. 0x0F0F0F0F) .|. ((x3 .&. 0x0F0F0F0F) `shiftLL` 4) of
                   x4 -> case ((x4 `shiftRL` 8) .&. 0x00FF00FF) .|. ((x4 .&. 0x00FF00FF) `shiftLL` 8) of
                     x5 -> ( x5 `shiftRL` 16             ) .|. ( x5               `shiftLL` 16);
#else
revNat x1 = case ((x1 `shiftRL` 1) .&. 0x5555555555555555) .|. ((x1 .&. 0x5555555555555555) `shiftLL` 1) of
              x2 -> case ((x2 `shiftRL` 2) .&. 0x3333333333333333) .|. ((x2 .&. 0x3333333333333333) `shiftLL` 2) of
                 x3 -> case ((x3 `shiftRL` 4) .&. 0x0F0F0F0F0F0F0F0F) .|. ((x3 .&. 0x0F0F0F0F0F0F0F0F) `shiftLL` 4) of
                   x4 -> case ((x4 `shiftRL` 8) .&. 0x00FF00FF00FF00FF) .|. ((x4 .&. 0x00FF00FF00FF00FF) `shiftLL` 8) of
                     x5 -> case ((x5 `shiftRL` 16) .&. 0x0000FFFF0000FFFF) .|. ((x5 .&. 0x0000FFFF0000FFFF) `shiftLL` 16) of
                       x6 -> ( x6 `shiftRL` 32             ) .|. ( x6               `shiftLL` 32);
#endif
foldrBits prefix f z bitmap = go (revNat bitmap) z
  where go bm acc | bm == 0 = acc
                  | otherwise = case lowestBitMask bm of
                                  bitmask -> bitmask `seq` case indexOfTheOnlyBit bitmask of
                                    bi -> bi `seq` go (bm `xor` bitmask) ((f $! (prefix+(WORD_SIZE_IN_BITS-1)-bi)) acc)
