-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Generate
-- Copyright   :  (c) Joshua Hawkins 2013
-- License     :  BSD-like
--
-- Maintainer  :  josh.r.hawk@gmail.com
-- Portability :  portable
--
-- Interface for generating modules with optional testing.
--
-----------------------------------------------------------------------------
module Distribution.Client.Generate
    (
     generate
    )
    where

import Distribution.Verbosity (Verbosity)

import Distribution.Client.Generate.Types
  ( GenerateFlags(..) )
import Distribution.Simple.Utils
  ( writeFileAtomic, warn, notice )

generate :: Verbosity
          -> GenerateFlags
          -> IO ()

generate verbosity generateFlags = do
  putStrLn "hi guys"
