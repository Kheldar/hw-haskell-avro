{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeFamilies         #-}

module Data.Avro.Encode
  ( -- * High level interface
    getSchema
  , encodeAvro
  , encodeContainer, encodeContainerWithSync
  -- * Lower level interface
  , EncodeAvro(..)
  , Zag(..)
  , putAvro
  ) where

import Prelude as P
import qualified Data.Aeson as A
import           Data.Array              (Array)
import           Data.Ix                 (Ix)
import           Data.Bits
import           Data.ByteString.Lazy    as BL
import qualified Data.Binary.IEEE754     as IEEE
import           Data.ByteString.Lazy.Char8 ()
import qualified Data.ByteString         as B
import           Data.ByteString.Builder
import qualified Data.Foldable           as F
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import           Data.Int
import           Data.List               as DL
import           Data.List.NonEmpty      (NonEmpty(..))
import qualified Data.List.NonEmpty      as NE
import           Data.Monoid
import           Data.Maybe              (catMaybes, mapMaybe)
import           Data.Set                (Set)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as T
import qualified Data.Text.Lazy          as TL
import qualified Data.Text.Lazy.Encoding as TL
import           Data.Vector             (Vector)
import qualified Data.Vector.Unboxed     as U
import           Data.Word
import           Data.Proxy
import           System.Entropy (getEntropy)

import Data.Avro.EncodeRaw
import Data.Avro.Schema as S
import Data.Avro.Types  as T
import Data.Avro.Zag
import Data.Avro.Zig

encodeAvro :: EncodeAvro a => a -> BL.ByteString
encodeAvro = toLazyByteString . putAvro

-- |Encode chunks of objects into a container, using 16 random bytes for
-- the synchronization markers.
encodeContainer :: EncodeAvro a => [[a]] -> IO BL.ByteString
encodeContainer xss =
  do sync <- getEntropy 16
     return $ encodeContainerWithSync (BL.fromStrict sync) xss

-- |Encode chunks of objects into a container, using the provided
-- ByteString as the synchronization markers.
encodeContainerWithSync :: EncodeAvro a => BL.ByteString -> [[a]] -> BL.ByteString
encodeContainerWithSync syncBytes xss =
 toLazyByteString $
  lazyByteString avroMagicBytes <>
  putAvro (HashMap.fromList [("avro.schema", A.encode objSchema), ("avro.codec","null")] :: HashMap Text BL.ByteString) <>
  lazyByteString syncBytes <>
  foldMap putBlocks xss
 where
  objSchema    = getSchema (P.head (P.head xss))
  putBlocks ys =
    let nrObj    = P.length ys
        nrBytes  = BL.length theBytes
        theBytes = toLazyByteString $ foldMap putAvro ys
    in putAvro nrObj <>
       putAvro nrBytes <>
       lazyByteString theBytes <>
       lazyByteString syncBytes
  avroMagicBytes :: BL.ByteString
  avroMagicBytes = "Obj" <> BL.pack [1]

-- XXX make an instance 'EncodeAvro Schema'
-- Would require a schema schema...
-- encodeSchema :: EncodeAvro a => a -> BL.ByteString
-- encodeSchema = toLazyByteString . putAvro . getSchema

putAvro :: EncodeAvro a => a -> Builder
putAvro   = fst . runAvro . avro

getSchema :: forall a. EncodeAvro a => a -> Schema
getSchema _ = getType (Proxy :: Proxy a)

getType :: EncodeAvro a => Proxy a -> Type
getType p = snd (runAvro (avro (undefined `asProxyTypeOf` p)))
-- N.B. ^^^ Local knowledge that 'fst' won't be used,
-- so the bottom of 'undefined' will not escape so long as schema creation
-- remains lazy in the argument.

newtype AvroM = AvroM { runAvro :: (Builder,Type) }

class EncodeAvro a where
  avro :: a -> AvroM

-- class PutAvro a where
--   putAvro :: a -> Builder

avroInt :: forall a. (FiniteBits a, Integral a, EncodeRaw a) => a -> AvroM
avroInt n = AvroM (encodeRaw n, S.Int)

avroLong :: forall a. (FiniteBits a, Integral a, EncodeRaw a) => a -> AvroM
avroLong n = AvroM (encodeRaw n, S.Long)

-- Put a Haskell Int.
putI :: Int -> Builder
putI = encodeRaw

instance EncodeAvro Int  where
  avro = avroInt
instance EncodeAvro Int8  where
  avro = avroInt
instance EncodeAvro Int16  where
  avro = avroInt
instance EncodeAvro Int32  where
  avro = avroInt
instance EncodeAvro Int64  where
  avro = avroInt
instance EncodeAvro Word8 where
  avro = avroInt
instance EncodeAvro Word16 where
  avro = avroInt
instance EncodeAvro Word32 where
  avro = avroLong
instance EncodeAvro Word64 where
  avro = avroLong
instance EncodeAvro Text where
  avro t =
    let bs = T.encodeUtf8 t
    in AvroM (encodeRaw (B.length bs) <> byteString bs, S.String)
instance EncodeAvro TL.Text where
  avro t =
    let bs = TL.encodeUtf8 t
    in AvroM (encodeRaw (BL.length bs) <> lazyByteString bs, S.String)

instance EncodeAvro ByteString where
  avro bs = AvroM (encodeRaw (BL.length bs) <> lazyByteString bs, S.Bytes)

instance EncodeAvro B.ByteString where
  avro bs = AvroM (encodeRaw (B.length bs) <> byteString bs, S.Bytes)

instance EncodeAvro String where
  avro s = let t = T.pack s in avro t

instance EncodeAvro Double where
  avro d = AvroM (word64LE (IEEE.doubleToWord d), S.Double)

instance EncodeAvro Float where
  avro d = AvroM (word32LE (IEEE.floatToWord d), S.Float)

instance EncodeAvro a => EncodeAvro [a] where
  avro xs = AvroM ( encodeRaw (F.length xs) <> foldMap putAvro xs
                  , S.Array (getType (Proxy :: Proxy a))
                  )

instance (Ix i, EncodeAvro a) => EncodeAvro (Array i a) where
  avro a = AvroM ( encodeRaw (F.length a) <> foldMap putAvro a
                 , S.Array (getType (Proxy :: Proxy a))
                 )
instance EncodeAvro a => EncodeAvro (Vector a) where
  avro a = AvroM ( encodeRaw (F.length a) <> foldMap putAvro a
                 , S.Array (getType (Proxy :: Proxy a))
                 )
instance (U.Unbox a, EncodeAvro a) => EncodeAvro (U.Vector a) where
  avro a = AvroM ( encodeRaw (U.length a) <> foldMap putAvro (U.toList a)
                 , S.Array (getType (Proxy :: Proxy a))
                 )

instance EncodeAvro a => EncodeAvro (Set a) where
  avro a = AvroM ( encodeRaw (F.length a) <> foldMap putAvro a
                 , S.Array (getType (Proxy :: Proxy a))
                 )

instance EncodeAvro a => EncodeAvro (HashMap Text a) where
  avro hm = AvroM ( putI (F.length hm) <> foldMap putKV (HashMap.toList hm)
                  , S.Map (getType (Proxy :: Proxy a))
                  )
    where putKV (k,v) = putAvro k <> putAvro v

-- XXX more from containers
-- XXX Unordered containers

-- | Maybe is modeled as a sum type `{null, a}`.
instance EncodeAvro a => EncodeAvro (Maybe a) where
  avro Nothing  = AvroM (putI 0             , S.mkUnion (S.Null:|[S.Int]))
  avro (Just x) = AvroM (putI 1 <> putAvro x, S.mkUnion (S.Null:|[S.Int]))

instance EncodeAvro () where
  avro () = AvroM (mempty, S.Null)

instance EncodeAvro Bool where
  avro b = AvroM (word8 $ fromIntegral $ fromEnum b, S.Boolean)

--------------------------------------------------------------------------------
--  Common Intermediate Representation Encoding

instance EncodeAvro (T.Value Type) where
  avro v =
    case v of
      T.Null      -> avro ()
      T.Boolean b -> avro b
      T.Int i     -> avro i
      T.Long i    -> avro i
      T.Float f   -> avro f
      T.Double d  -> avro d
      T.Bytes bs  -> avro bs
      T.String t  -> avro t
      T.Array vec -> avro vec
      T.Map hm    -> avro hm
      T.Record ty hm ->
        let bs = foldMap putAvro (mapMaybe (`HashMap.lookup` hm) fs)
            fs = P.map fldName (fields ty)
        in AvroM (bs, ty)
      T.Union opts sel val | F.length opts > 0 ->
        case DL.elemIndex sel (NE.toList opts) of
          Just idx -> AvroM (putI idx <> putAvro val, S.mkUnion opts)
          Nothing  -> error "Union encoding specifies type not found in schema"
      T.Fixed bs  -> avro bs
      T.Enum sch@S.Enum{..} ix t -> AvroM (putI ix, sch)
