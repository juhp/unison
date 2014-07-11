module Unison.Hash where

import Unison.Parser as P

data Hash = Hash String

base64 h = case h of 
  Hash s -> s

parse : P.Parser Hash
parse = P.map Hash P.string
