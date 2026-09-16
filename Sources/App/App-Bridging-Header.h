//  App-Bridging-Header.h
//  本体が要るのはリンクの受け側だけ。MDPDriver.h は拡張のもので、ここには要らない。
//  MDP_LINK_PORT もここから Swift に見える（画面の待ち受けの表示に使う）。

#import "LocalLink.h"
