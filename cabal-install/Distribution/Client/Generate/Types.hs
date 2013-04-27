-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Generate.Types
-- Copyright   :  (c) Joshua Hawkins 2013
-- License     :  BSD-like
--
-- Maintainer  :  josh.r.hawk@gmail.com
-- Portability :  portable
--
-- Some types used by the 'cabal generate' command.
--
-----------------------------------------------------------------------------
module Distribution.Client.Generate.Types where

import Distribution.Verbosity
import Distribution.Simple.Setup
  ( Flag(..) )

-- | GenerateFlags -> add some comments
data GenerateFlags =
     GenerateFlags { testSuite :: Flag Bool
                   , benchmark :: Flag Bool
                   , generateVerbosity :: Flag Verbosity
                   }
  deriving (Show)
