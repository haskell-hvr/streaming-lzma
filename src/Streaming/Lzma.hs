{-# LANGUAGE LambdaCase  #-}
{-# LANGUAGE Trustworthy #-}

-- |
-- Module      : Streaming.Lzma
-- Copyright   : © 2019 Herbert Valerio Riedel
--
-- Maintainer  : hvr@gnu.org
--
-- Compression and decompression of data streams in the LZMA/XZ format.
--
module Streaming.Lzma
    ( -- * Simple interface
      compress
    , decompress
    , decompress_

      -- * Extended interface
      -- ** Compression
    , compressWith

    , Lzma.defaultCompressParams
    , Lzma.CompressParams

    , Lzma.compressLevel
    , Lzma.CompressionLevel(..)
    , Lzma.compressLevelExtreme
    , Lzma.IntegrityCheck(..)
    , Lzma.compressIntegrityCheck

      -- ** Decompression
    , decompressWith

    , Lzma.defaultDecompressParams
    , Lzma.DecompressParams

    , Lzma.decompressTellNoCheck
    , Lzma.decompressTellUnsupportedCheck
    , Lzma.decompressTellAnyCheck
    , Lzma.decompressConcatenated
    , Lzma.decompressAutoDecoder
    , Lzma.decompressMemLimit

    ) where

import qualified Codec.Compression.Lzma  as Lzma
import           Control.Exception         (throwIO)
import qualified Data.ByteString           as B
import           Data.ByteString.Streaming (ByteString, chunk, effects,
                                            nextChunk, null_)
import           Streaming                 (MonadIO (liftIO), lift)

-- | Decompress a compressed LZMA/XZ stream.
--
-- The monadic return value is a stream representing the possibly
-- unconsumed leftover data from the input stream; see also 'decompress_'.
--
-- __NOTE__: 'Lzma.decompressConcatenated' is disabled in this operation
decompress :: MonadIO m
           => ByteString m r -- ^ compressed stream
           -> ByteString m (ByteString m r) -- ^ uncompressed stream
decompress = decompressWith Lzma.defaultDecompressParams { Lzma.decompressConcatenated = False }

-- | Convenience wrapper around 'decompress' which fails eagerly if
-- the compressed stream contains any trailing data
--
-- __NOTE__: 'Lzma.decompressConcatenated' is disabled in this operation
decompress_ :: MonadIO m
            => ByteString m r -- ^ compressed stream
            -> ByteString m r -- ^ uncompressed stream
decompress_ is = do
   mr <- decompress is
   lift $ do
      noLeftovers <- null_ mr
      if noLeftovers
       then effects mr
       else liftIO (throwIO Lzma.LzmaRetStreamEnd)

-- | Like 'decompress' but with the ability to specify various decompression
-- parameters. Typical usage:
--
-- __NOTE__: Be aware that 'Lzma.decompressConcatenated' is enabled by default in 'Lzma.defaultDecompressParams'.
--
-- > decompressWith defaultDecompressParams { decompress... = ... }
decompressWith :: MonadIO m
               => Lzma.DecompressParams
               -> ByteString m r -- ^ compressed stream
               -> ByteString m (ByteString m r) -- ^ uncompressed stream
decompressWith params stream0 =
    go stream0 =<< liftIO (Lzma.decompressIO params)
  where
    go stream enc@(Lzma.DecompressInputRequired cont) = do
        lift (nextChunk stream) >>= \case
            Right (ibs,stream')
               | B.null ibs -> go stream' enc -- should not happen
               | otherwise  -> go stream' =<< liftIO (cont ibs)
            Left r          -> go (pure r) =<< liftIO (cont B.empty)
    go stream (Lzma.DecompressOutputAvailable obs cont) = do
        chunk obs
        go stream =<< liftIO cont
    go stream (Lzma.DecompressStreamEnd leftover) =
        pure (chunk leftover >> stream)
    go _stream (Lzma.DecompressStreamError ecode) =
        liftIO (throwIO ecode)

-- | Compress into a LZMA/XZ compressed stream.
compress :: MonadIO m
         => ByteString m r -- ^ compressed stream
         -> ByteString m r -- ^ uncompressed stream
compress = compressWith Lzma.defaultCompressParams

-- | Like 'compress' but with the ability to specify various compression
-- parameters. Typical usage:
--
-- > compressWith defaultCompressParams { compress... = ... }
compressWith :: MonadIO m
             => Lzma.CompressParams
             -> ByteString m r -- ^ uncompressed stream
             -> ByteString m r -- ^ compressed stream
compressWith params stream0 =
    go stream0 =<< liftIO (Lzma.compressIO params)
  where
    go stream enc@(Lzma.CompressInputRequired _flush cont) = do
        lift (nextChunk stream) >>= \case
          Right (x, stream')
            | B.null x  -> go stream' enc -- should not happen
            | otherwise -> go stream' =<< liftIO (cont x)
          Left r        -> go (pure r) =<< liftIO (cont B.empty)
    go stream (Lzma.CompressOutputAvailable obs cont) = do
        chunk obs
        go stream =<< liftIO cont
    go stream Lzma.CompressStreamEnd = stream
