module U.Util.Map
  ( bimap,
    bitraverse,
    swap,
    valuesVector,
    traverseKeys,
    traverseKeysWith,
  )
where

import Control.Lens (traversed, (%%~), (&), _1)
import qualified Data.Bifunctor as B
import qualified Data.Bitraversable as B
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Vector (Vector)
import qualified Data.Vector as Vector

bimap :: Ord a' => (a -> a') -> (b -> b') -> Map a b -> Map a' b'
bimap fa fb = Map.fromList . map (B.bimap fa fb) . Map.toList

bitraverse :: (Applicative f, Ord a') => (a -> f a') -> (b -> f b') -> Map a b -> f (Map a' b')
bitraverse fa fb = fmap Map.fromList . traverse (B.bitraverse fa fb) . Map.toList

-- | 'swap' throws away data if the input contains duplicate values
swap :: Ord b => Map a b -> Map b a
swap =
  Map.foldlWithKey' (\z a b -> Map.insert b a z) mempty

valuesVector :: Map k v -> Vector v
valuesVector =
  Vector.fromList . Map.elems

traverseKeys :: (Applicative f, Ord k') => (k -> f k') -> Map k v -> f (Map k' v)
traverseKeys f m =
  Map.fromList <$> (Map.toList m & traversed . _1 %%~ f)

traverseKeysWith :: (Applicative f, Ord k') => (v -> v -> v) -> (k -> f k') -> Map k v -> f (Map k' v)
traverseKeysWith combine f m =
  Map.fromListWith combine <$> (Map.toList m & traversed . _1 %%~ f)
