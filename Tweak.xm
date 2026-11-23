#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import "engine.h"
#import "maia.h"

#define CH_ACCENT [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:1.0]

#define PREF_ELO     @"ChessAssist_ELO"
#define PREF_ENABLED @"ChessAssist_Enabled"
#define PREF_SHOWN   @"ChessAssist_CreditShown"
#define PREF_CREDIT2 @"ChessAssist_CreditShown2"
#define PREF_WINPCT  @"ChessAssist_WinPct"
#define PREF_ARROWS  @"ChessAssist_ArrowCount"
#define PREF_ALPHA   @"ChessAssist_ArrowAlpha"
#define PREF_THICK   @"ChessAssist_ArrowThick"
#define PREF_EVALCLR @"ChessAssist_ArrowEvalColor"
#define PREF_QUALITY @"ChessAssist_TrackQuality"
#define PREF_EVALLBL @"ChessAssist_EvalLabels"
#define PREF_EVALBAR @"ChessAssist_EvalBar"
#define PREF_USEMAIA @"ChessAssist_UseMaia"
#define PREF_AUTOPLAY @"ChessAssist_AutoPlay"
#define PREF_APDELAY  @"ChessAssist_AutoPlayDelay"
#define PREF_APJITEN  @"ChessAssist_AutoPlayJitterEnabled"
#define PREF_APJITRNG @"ChessAssist_AutoPlayJitterRange"
#define PREF_AP2ND    @"ChessAssist_AutoPlaySecondBest"
#define PREF_AP2NDPCT @"ChessAssist_AutoPlaySecondBestPct"
#define DEFAULT_ELO  800

static NSInteger gElo     = DEFAULT_ELO;
static BOOL      gEnabled = YES;
static NSString *gLastFen = nil;
static NSString *gPendingFen = nil;
static BOOL      gFetching = NO;
static NSDate   *gLastFetch = nil;
static __weak id gOnlineGame = nil;
static NSDate   *gLoadTime = nil;
static NSInteger gMyColor = -1;
static double    gLastEval = 0;
static BOOL      gHasEval  = NO;
static int       gForcedFlip = -1;
static BOOL      gShowWinPct = NO;
static NSInteger gArrowCount = 1;
static CGFloat   gArrowAlpha = 0.7;
static CGFloat   gArrowThick = 1.0;
static BOOL      gArrowEvalColor = YES;
static BOOL      gTrackQuality = YES;
static NSString *gQualFen = nil;
static double    gQualWhiteEval = 0;
static BOOL      gQualHave = NO;
static NSString *gLastQualDone = nil;
static double    gAccSum = 0;
static int       gAccCount = 0;
static NSString *gLastMoveQuality = nil;
static BOOL      gPuzzleCtx = NO;

enum { Q_BRILLIANT, Q_GREAT, Q_BEST, Q_EXCELLENT, Q_GOOD, Q_INACC, Q_MISS, Q_MISTAKE, Q_BLUNDER, Q_COUNT };
static int    gQ[Q_COUNT] = {0};
static double gQual2ndWhite = 0;
static BOOL   gQualHave2nd = NO;
static BOOL gShowEvalLabels = YES;
static BOOL gUseMaia = NO;
static BOOL gAutoPlay = NO;
static double gAutoPlayDelay = 0.15;
static BOOL gAutoPlayJitterEnabled = NO;
static double gAutoPlayJitterRange = 1.0;
static BOOL gAutoPlaySecondBest = NO;
static NSInteger gAutoPlaySecondBestPct = 10;
static NSString *gLastAutoPlayed = nil;
static NSMutableString *gUciSeq = nil;
static NSString *gPgnStartFen = nil;
static BOOL gShowEvalBar = YES;
static BOOL gBarHave = NO;
static double gBarWhiteEval = 0;
static BOOL gBarIsMate = NO;
static int gBarMateWhite = 0;
static BOOL gSkipNextTap = NO;

static NSMutableArray *gLog;
static NSString *gLogPath = nil;
static void dbg(NSString *msg) {
    if (!gLog) gLog = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], msg];
    [gLog addObject:line];
    while (gLog.count > 200) [gLog removeObjectAtIndex:0];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                    stringByAppendingPathComponent:@"chessassist.log"];
        [@"" writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    });
    if (gLogPath) {
        FILE *fp = fopen(gLogPath.fileSystemRepresentation, "a");
        if (fp) { fputs([line UTF8String], fp); fputc('\n', fp); fclose(fp); }
    }
}

static void savePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:gElo forKey:PREF_ELO];
    [d setBool:gEnabled forKey:PREF_ENABLED];
    [d setBool:gShowWinPct forKey:PREF_WINPCT];
    [d setInteger:gArrowCount forKey:PREF_ARROWS];
    [d setDouble:gArrowAlpha forKey:PREF_ALPHA];
    [d setDouble:gArrowThick forKey:PREF_THICK];
    [d setBool:gArrowEvalColor forKey:PREF_EVALCLR];
    [d setBool:gTrackQuality forKey:PREF_QUALITY];
    [d setBool:gShowEvalLabels forKey:PREF_EVALLBL];
    [d setBool:gUseMaia forKey:PREF_USEMAIA];
    [d setBool:gAutoPlay forKey:PREF_AUTOPLAY];
    [d setDouble:gAutoPlayDelay forKey:PREF_APDELAY];
    [d setBool:gShowEvalBar forKey:PREF_EVALBAR];
    [d setBool:gAutoPlayJitterEnabled forKey:PREF_APJITEN];
    [d setDouble:gAutoPlayJitterRange forKey:PREF_APJITRNG];
    [d setBool:gAutoPlaySecondBest forKey:PREF_AP2ND];
    [d setInteger:gAutoPlaySecondBestPct forKey:PREF_AP2NDPCT];
    [d synchronize];
}
static void loadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:PREF_ELO]) gElo = [d integerForKey:PREF_ELO];
    if ([d objectForKey:PREF_ENABLED]) gEnabled = [d boolForKey:PREF_ENABLED];
    if ([d objectForKey:PREF_WINPCT]) gShowWinPct = [d boolForKey:PREF_WINPCT];
    if ([d objectForKey:PREF_ARROWS]) gArrowCount = [d integerForKey:PREF_ARROWS];
    if ([d objectForKey:PREF_ALPHA])  gArrowAlpha = [d doubleForKey:PREF_ALPHA];
    if ([d objectForKey:PREF_THICK])  gArrowThick = [d doubleForKey:PREF_THICK];
    if ([d objectForKey:PREF_EVALCLR]) gArrowEvalColor = [d boolForKey:PREF_EVALCLR];
    if ([d objectForKey:PREF_QUALITY]) gTrackQuality = [d boolForKey:PREF_QUALITY];
    if ([d objectForKey:PREF_EVALLBL]) gShowEvalLabels = [d boolForKey:PREF_EVALLBL];
    if ([d objectForKey:PREF_USEMAIA]) gUseMaia = [d boolForKey:PREF_USEMAIA];
    if ([d objectForKey:PREF_AUTOPLAY]) gAutoPlay = [d boolForKey:PREF_AUTOPLAY];
    if ([d objectForKey:PREF_APDELAY]) {
        gAutoPlayDelay = [d doubleForKey:PREF_APDELAY];
        if (gAutoPlayDelay < 0) gAutoPlayDelay = 0;
        if (gAutoPlayDelay > 5.0) gAutoPlayDelay = 5.0;
    }
    if ([d objectForKey:PREF_EVALBAR]) gShowEvalBar = [d boolForKey:PREF_EVALBAR];
    if ([d objectForKey:PREF_APJITEN]) gAutoPlayJitterEnabled = [d boolForKey:PREF_APJITEN];
    if ([d objectForKey:PREF_APJITRNG]) {
        gAutoPlayJitterRange = [d doubleForKey:PREF_APJITRNG];
        if (gAutoPlayJitterRange < 0) gAutoPlayJitterRange = 0;
        if (gAutoPlayJitterRange > 2.0) gAutoPlayJitterRange = 2.0;
    }
    if ([d objectForKey:PREF_AP2ND]) gAutoPlaySecondBest = [d boolForKey:PREF_AP2ND];
    if ([d objectForKey:PREF_AP2NDPCT]) {
        gAutoPlaySecondBestPct = [d integerForKey:PREF_AP2NDPCT];
    }
    if (gAutoPlaySecondBestPct < 0) gAutoPlaySecondBestPct = 0;
    if (gAutoPlaySecondBestPct > 50) gAutoPlaySecondBestPct = 50;
    if (gArrowCount < 1) gArrowCount = 1; if (gArrowCount > 3) gArrowCount = 3;
}

static double evalToWinPct(double pawns, BOOL isMate, int mateIn) {
    if (isMate) return mateIn > 0 ? 100.0 : 0.0;
    double cp = pawns * 100.0;
    double w = 50.0 + 50.0 * (2.0 / (1.0 + exp(-0.00368208 * cp)) - 1.0);
    if (w < 0) w = 0; if (w > 100) w = 100;
    return w;
}

static NSInteger eloToDepth(NSInteger elo) {
    if (elo >= 3000) return 20;  if (elo >= 2600) return 18;
    if (elo >= 2400) return 16;  if (elo >= 2200) return 14;
    if (elo >= 2000) return 13;  if (elo >= 1800) return 12;
    if (elo >= 1600) return 11;  if (elo >= 1400) return 10;
    if (elo >= 1200) return 9;   if (elo >= 1000) return 8;
    if (elo >= 700)  return 6;   if (elo >= 500) return 5;
    return 4;
}

static void showQualityToast(NSString *text, UIColor *color);
static void ensureMaiaLoaded(void);
static NSString *buildPGN(void);
static void updateEvalBar(void);
static void removeEvalBar(void);

static NSString *formatEvalLabel(double evalUs, BOOL isMate, int mateIn) {
    if (isMate) return [NSString stringWithFormat:@"M%d", abs(mateIn)];
    if (gShowWinPct) return [NSString stringWithFormat:@"%.0f%%", evalToWinPct(evalUs, NO, 0)];
    return [NSString stringWithFormat:@"%+.1f", evalUs];
}

static NSString *qName(int i) {
    switch (i) {
        case Q_BRILLIANT: return @"Brilliant";  case Q_GREAT:   return @"Great";
        case Q_BEST:      return @"Best";        case Q_EXCELLENT: return @"Excellent";
        case Q_GOOD:      return @"Good";        case Q_INACC:   return @"Inaccuracy";
        case Q_MISS:      return @"Miss";        case Q_MISTAKE: return @"Mistake";
        default:          return @"Blunder";
    }
}
static NSString *qSymbol(int i) {
    switch (i) {
        case Q_BRILLIANT: return @"!!";  case Q_GREAT:   return @"!";
        case Q_BEST:      return @"★";    case Q_EXCELLENT: return @"✓";
        case Q_GOOD:      return @"•";    case Q_INACC:   return @"?!";
        case Q_MISS:      return @"✗";    case Q_MISTAKE: return @"?";
        default:          return @"??";
    }
}
static UIColor *qColor(int i) {
    switch (i) {
        case Q_BRILLIANT: return [UIColor colorWithRed:0.0 green:0.78 blue:0.78 alpha:1];
        case Q_GREAT:     return [UIColor colorWithRed:0.30 green:0.55 blue:0.95 alpha:1];
        case Q_BEST:      return [UIColor systemGreenColor];
        case Q_EXCELLENT: return [UIColor colorWithRed:0.40 green:0.73 blue:0.42 alpha:1];
        case Q_GOOD:      return [UIColor systemTealColor];
        case Q_INACC:     return [UIColor systemYellowColor];
        case Q_MISS:      return [UIColor colorWithRed:0.95 green:0.45 blue:0.20 alpha:1];
        case Q_MISTAKE:   return [UIColor systemOrangeColor];
        default:          return [UIColor systemRedColor];
    }
}

static double moveAccuracy(double winBefore, double winAfter) {
    double wl = winBefore - winAfter; if (wl < 0) wl = 0;
    double a = 103.1668 * exp(-0.04354 * wl) - 3.1669;
    if (a < 0) a = 0; if (a > 100) a = 100;
    return a;
}

static int fenMaterial(NSString *fen, int color ) {
    NSString *place = [[fen componentsSeparatedByString:@" "] firstObject];
    int sum = 0;
    for (NSUInteger i = 0; i < place.length; i++) {
        unichar ch = [place characterAtIndex:i];
        BOOL isW = (ch >= 'A' && ch <= 'Z'), isB = (ch >= 'a' && ch <= 'z');
        if (!isW && !isB) continue;
        unichar u = isW ? ch : (unichar)(ch - 32);
        int v = (u=='P')?1 : (u=='N'||u=='B')?3 : (u=='R')?5 : (u=='Q')?9 : 0;
        if ((color == 0 && isW) || (color == 1 && isB)) sum += v;
    }
    return sum;
}

// Grade on win-% loss (chess.com-style) instead of raw centipawns — far more
// stable across shallow searches, so genuinely best moves stop showing as
// "Inaccuracy" from ±30cp eval noise.
static int classifyMove(double winLoss, BOOL playedBest, BOOL onlyGood, BOOL sacrificed) {
    if (playedBest && sacrificed) return Q_BRILLIANT;
    if (playedBest && onlyGood)   return Q_GREAT;
    if (winLoss <= 0.5)  return Q_BEST;
    if (winLoss <= 2.0)  return Q_EXCELLENT;
    if (winLoss <= 5.0)  return Q_GOOD;
    if (winLoss <= 10.0) return Q_INACC;
    if (winLoss <= 20.0) return Q_MISTAKE;
    return Q_BLUNDER;
}

static void resetAccuracy(void) {
    gAccSum = 0; gAccCount = 0; gLastMoveQuality = nil;
    for (int i = 0; i < Q_COUNT; i++) gQ[i] = 0;
    gQualHave = NO; gQualHave2nd = NO; gLastQualDone = nil;
}

static void noteUserEval(NSString *fen, double whiteEval, BOOL valid,
                         double secondWhite, BOOL have2nd) {
    gQualFen = [fen copy];
    gQualWhiteEval = whiteEval;
    gQualHave = valid;
    gQual2ndWhite = secondWhite;
    gQualHave2nd = have2nd;
}

static void analyzeUserMove(NSString *oppFen) {
    if (!gTrackQuality || !oppFen.length) return;
    if ([oppFen isEqualToString:gLastQualDone]) return;
    gLastQualDone = [oppFen copy];
    if (!gQualHave) return;
    if ([oppFen isEqualToString:gQualFen]) return;
    if (gMyColor < 0) return;

    double beforeWhite = gQualWhiteEval;
    double secondWhite = gQual2ndWhite;
    BOOL   have2nd     = gQualHave2nd;
    NSString *beforeFen = [gQualFen copy];
    int    userColor   = gMyColor;
    BOOL   stmWhite    = ([oppFen rangeOfString:@" w "].location != NSNotFound);
    NSInteger depth    = MAX(14, eloToDepth(gElo)); // stable evals matter more than speed here

    EngineGo([oppFen UTF8String], (int)depth, (int)gElo, 1,
             ^(const EngineLine *lines, int count) {
        BOOL hs   = count > 0 && lines[0].hasScore;
        BOOL mate = count > 0 && lines[0].isMate;
        int  sc   = count > 0 ? lines[0].score : 0;
        if (!hs || mate) return;
        double afterWhite = (sc / 100.0) * (stmWhite ? 1 : -1);
        dispatch_async(dispatch_get_main_queue(), ^{
            double beforeUs = (userColor == 1) ? -beforeWhite : beforeWhite;
            double afterUs  = (userColor == 1) ? -afterWhite  : afterWhite;
            double secondUs = (userColor == 1) ? -secondWhite : secondWhite;

            double winBefore = evalToWinPct(beforeUs, NO, 0);
            double winAfter  = evalToWinPct(afterUs, NO, 0);
            double winLoss   = winBefore - winAfter;
            if (winLoss < 0) winLoss = 0;

            BOOL playedBest = winLoss <= 0.5;
            BOOL onlyGood   = have2nd && (beforeUs - secondUs) >= 1.5;

            int dBefore = fenMaterial(beforeFen, userColor) - fenMaterial(beforeFen, 1 - userColor);
            int dAfter  = fenMaterial(oppFen,    userColor) - fenMaterial(oppFen,    1 - userColor);
            BOOL sacrificed = (dAfter <= -2) && (dAfter < dBefore);

            int cat = classifyMove(winLoss, playedBest, onlyGood, sacrificed);
            gQ[cat]++;
            double acc = moveAccuracy(winBefore, winAfter);
            gAccSum += acc; gAccCount++;
            gLastMoveQuality = [NSString stringWithFormat:@"%@ (-%.1f%%)", qName(cat), winLoss];
            showQualityToast([NSString stringWithFormat:@"%@ %@", qSymbol(cat), qName(cat)], qColor(cat));
        });
    });
}

static char gBoard[64];
static int  gSide;
static int  gCastle;
static int  gEp;
static int  gHalf;
static int  gFull;

static void parseFEN(NSString *fen) {
    memset(gBoard, ' ', 64);
    gSide = 0; gCastle = 0; gEp = -1; gHalf = 0; gFull = 1;
    if (!fen.length) fen = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    NSString *placement = parts[0];
    int sq = 56;
    for (NSUInteger i = 0; i < placement.length; i++) {
        unichar c = [placement characterAtIndex:i];
        if (c == '/') { sq -= 16; }
        else if (c >= '1' && c <= '8') { sq += (c - '0'); }
        else { if (sq >= 0 && sq < 64) gBoard[sq] = (char)c; sq++; }
    }
    if (parts.count > 1) gSide = [[parts[1] lowercaseString] isEqualToString:@"b"] ? 1 : 0;
    if (parts.count > 2) {
        NSString *cas = parts[2];
        if ([cas containsString:@"K"]) gCastle |= 1;
        if ([cas containsString:@"Q"]) gCastle |= 2;
        if ([cas containsString:@"k"]) gCastle |= 4;
        if ([cas containsString:@"q"]) gCastle |= 8;
    }
    if (parts.count > 3 && ![parts[3] isEqualToString:@"-"]) {
        NSString *ep = parts[3];
        if (ep.length >= 2) {
            int file = [ep characterAtIndex:0] - 'a';
            int rank = [ep characterAtIndex:1] - '1';
            if (file >= 0 && file < 8 && rank >= 0 && rank < 8) gEp = rank * 8 + file;
        }
    }
    if (parts.count > 4) gHalf = [parts[4] intValue];
    if (parts.count > 5) gFull = [parts[5] intValue];
}

static void applyMove(int from, int to, char promo) {
    if (from < 0 || from > 63 || to < 0 || to > 63) return;
    char piece = gBoard[from];
    char captured = gBoard[to];
    gBoard[from] = ' ';
    if ((piece == 'P' || piece == 'p') && to == gEp) {
        int capSq = (piece == 'P') ? to - 8 : to + 8;
        if (capSq >= 0 && capSq < 64) gBoard[capSq] = ' ';
    }
    if (piece == 'K' && from == 4) {
        if (to == 6) { gBoard[5] = gBoard[7]; gBoard[7] = ' '; }
        else if (to == 2) { gBoard[3] = gBoard[0]; gBoard[0] = ' '; }
    }
    if (piece == 'k' && from == 60) {
        if (to == 62) { gBoard[61] = gBoard[63]; gBoard[63] = ' '; }
        else if (to == 58) { gBoard[59] = gBoard[56]; gBoard[56] = ' '; }
    }
    if (promo) gBoard[to] = (gSide == 0) ? (char)toupper(promo) : (char)tolower(promo);
    else gBoard[to] = piece;
    gEp = -1;
    if (piece == 'P' && (to - from) == 16) gEp = from + 8;
    if (piece == 'p' && (from - to) == 16) gEp = from - 8;
    if (piece == 'K') gCastle &= ~3;
    if (piece == 'k') gCastle &= ~12;
    if (from == 0 || to == 0) gCastle &= ~2;
    if (from == 7 || to == 7) gCastle &= ~1;
    if (from == 56 || to == 56) gCastle &= ~8;
    if (from == 63 || to == 63) gCastle &= ~4;
    if (piece == 'P' || piece == 'p' || captured != ' ') gHalf = 0; else gHalf++;
    if (gSide == 1) gFull++;
    gSide = 1 - gSide;
}

static NSString *generateFEN(void) {
    NSMutableString *fen = [NSMutableString string];
    for (int rank = 7; rank >= 0; rank--) {
        int empty = 0;
        for (int file = 0; file < 8; file++) {
            char p = gBoard[rank * 8 + file];
            if (p == ' ') { empty++; }
            else {
                if (empty) { [fen appendFormat:@"%d", empty]; empty = 0; }
                [fen appendFormat:@"%c", p];
            }
        }
        if (empty) [fen appendFormat:@"%d", empty];
        if (rank > 0) [fen appendString:@"/"];
    }
    [fen appendFormat:@" %c ", gSide == 0 ? 'w' : 'b'];
    NSMutableString *cas = [NSMutableString string];
    if (gCastle & 1) [cas appendString:@"K"];
    if (gCastle & 2) [cas appendString:@"Q"];
    if (gCastle & 4) [cas appendString:@"k"];
    if (gCastle & 8) [cas appendString:@"q"];
    [fen appendString:cas.length ? cas : @"-"];
    if (gEp >= 0) [fen appendFormat:@" %c%c", 'a'+(gEp%8), '1'+(gEp/8)];
    else [fen appendString:@" -"];
    [fen appendFormat:@" %d %d", gHalf, gFull];
    return fen;
}

static NSString *TCN_TABLE = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?{~}(^)[_]@#$,./`-*+=";

static int tcnIndex(unichar c) {
    NSUInteger idx = [TCN_TABLE rangeOfString:[NSString stringWithCharacters:&c length:1]].location;
    return (idx == NSNotFound) ? -1 : (int)idx;
}

static NSString *decodeTCNToFEN(NSString *initialFEN, NSString *encoded) {
    parseFEN(initialFEN);
    gPgnStartFen = [initialFEN copy];
    if (!gUciSeq) gUciSeq = [NSMutableString string];
    [gUciSeq setString:@""];
    if (!encoded.length) return generateFEN();
    for (NSUInteger i = 0; i + 1 < encoded.length; i += 2) {
        int fromIdx = tcnIndex([encoded characterAtIndex:i]);
        int toIdx   = tcnIndex([encoded characterAtIndex:i + 1]);
        if (fromIdx < 0 || fromIdx > 63 || toIdx < 0) continue;
        int from = fromIdx, to;
        char promo = 0;
        if (toIdx <= 63) {
            to = toIdx;
        } else {
            int offset = toIdx - 64;
            int pieceIdx = offset / 3;
            int dir = offset % 3;
            static const char promoChars[] = "qnrb";
            if (pieceIdx < 4) promo = promoChars[pieceIdx];
            int fromFile = from % 8;
            int toFile = fromFile + dir - 1;
            to = (from >= 48) ? (56 + toFile) : (0 + toFile);
        }
        applyMove(from, to, promo);
        char u[6] = { (char)('a' + from % 8), (char)('1' + from / 8),
                      (char)('a' + to % 8),   (char)('1' + to / 8),
                      (char)(promo ? tolower((unsigned char)promo) : 0), 0 };
        [gUciSeq appendFormat:@"%s ", u];
    }
    return generateFEN();
}

static NSMutableArray<CALayer *> *gArrowLayers = nil;
static __weak UIView *gBoardView = nil;
static __weak UIView *gBotBoard  = nil;
static __weak UIView *gPuzzleBoard = nil;
static __weak UIView *gDrawBoard = nil;
static __weak UIView *gOnlineDrawBoard = nil;
static NSDate *gBotSeen    = nil;
static NSDate *gOnlineSeen = nil;
static NSArray *gCurrentArrows = nil;
static BOOL    gArrowFlipped = NO;

static CGPoint squareToPoint(int sq, CGRect bounds, BOOL flipped) {
    int file = sq % 8;
    int rank = sq / 8;
    CGFloat sqW = bounds.size.width / 8.0;
    CGFloat sqH = bounds.size.height / 8.0;
    CGFloat x, y;
    if (flipped) {
        x = (7 - file) * sqW + sqW / 2.0;
        y = rank * sqH + sqH / 2.0;
    } else {
        x = file * sqW + sqW / 2.0;
        y = (7 - rank) * sqH + sqH / 2.0;
    }
    return CGPointMake(x, y);
}

static BOOL parseMoveUCI(NSString *move, int *fromSq, int *toSq) {
    if (move.length < 4) return NO;
    int ff = [move characterAtIndex:0] - 'a';
    int fr = [move characterAtIndex:1] - '1';
    int tf = [move characterAtIndex:2] - 'a';
    int tr = [move characterAtIndex:3] - '1';
    if (ff < 0 || ff > 7 || fr < 0 || fr > 7 || tf < 0 || tf > 7 || tr < 0 || tr > 7) return NO;
    *fromSq = fr * 8 + ff;
    *toSq   = tr * 8 + tf;
    return YES;
}

static UIBezierPath *arrowPath(CGPoint from, CGPoint to, CGFloat headLen, CGFloat headW, CGFloat shaftW) {
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat len = sqrtf(dx * dx + dy * dy);
    if (len < 1) return nil;

    CGFloat ux = dx / len, uy = dy / len;
    CGFloat px = -uy,      py = ux;

    CGPoint shaftL1 = { from.x + px * shaftW / 2, from.y + py * shaftW / 2 };
    CGPoint shaftR1 = { from.x - px * shaftW / 2, from.y - py * shaftW / 2 };
    CGPoint neckL   = { to.x - ux * headLen + px * shaftW / 2, to.y - uy * headLen + py * shaftW / 2 };
    CGPoint neckR   = { to.x - ux * headLen - px * shaftW / 2, to.y - uy * headLen - py * shaftW / 2 };
    CGPoint wingL   = { to.x - ux * headLen + px * headW / 2,  to.y - uy * headLen + py * headW / 2 };
    CGPoint wingR   = { to.x - ux * headLen - px * headW / 2,  to.y - uy * headLen - py * headW / 2 };

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:shaftL1];
    [path addLineToPoint:neckL];
    [path addLineToPoint:wingL];
    [path addLineToPoint:to];
    [path addLineToPoint:wingR];
    [path addLineToPoint:neckR];
    [path addLineToPoint:shaftR1];
    [path closePath];
    return path;
}

static void clearArrow(void) {
    if (gArrowLayers) {
        for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
        [gArrowLayers removeAllObjects];
    }
    gCurrentArrows = nil;
}

static CALayer *buildArrowLayer(NSString *moveUCI, CGRect bounds, BOOL flipped,
                                double evalForUs, int rank) {
    int fromSq = 0, toSq = 0;
    if (!parseMoveUCI(moveUCI, &fromSq, &toSq)) return nil;
    if (bounds.size.width < 8) return nil;

    CGFloat sqSize = bounds.size.width / 8.0;
    CGPoint fromPt = squareToPoint(fromSq, bounds, flipped);
    CGPoint toPt   = squareToPoint(toSq,   bounds, flipped);

    CGFloat t = gArrowThick;
    UIBezierPath *path = arrowPath(fromPt, toPt, sqSize * 0.45, sqSize * 0.65 * t, sqSize * 0.18 * t);
    if (!path) return nil;

    CGFloat a = (rank > 0) ? (gArrowAlpha * 0.55) : gArrowAlpha;

    // Контейнер для стрелки
    CALayer *container = [CALayer layer];
    container.frame = bounds;
    container.zPosition = 10000;

    // Переливающийся черно-красный градиент
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = bounds;
    grad.opacity = (float)a;
    grad.colors = @[
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.06 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.88 green:0.08 blue:0.15 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.12 green:0.02 blue:0.04 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.95 green:0.14 blue:0.20 alpha:1.0].CGColor
    ];
    grad.locations = @[@0.0, @0.35, @0.7, @1.0];
    grad.startPoint = CGPointMake(0.0, 0.0);
    grad.endPoint   = CGPointMake(1.0, 1.0);

    // Маска по форме стрелки
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = path.CGPath;
    grad.mask = mask;

    // Анимация перелива градиента
    CABasicAnimation *animStart = [CABasicAnimation animationWithKeyPath:@"startPoint"];
    animStart.fromValue = [NSValue valueWithCGPoint:CGPointMake(0.0, 0.0)];
    animStart.toValue   = [NSValue valueWithCGPoint:CGPointMake(1.0, 0.0)];

    CABasicAnimation *animEnd = [CABasicAnimation animationWithKeyPath:@"endPoint"];
    animEnd.fromValue = [NSValue valueWithCGPoint:CGPointMake(1.0, 1.0)];
    animEnd.toValue   = [NSValue valueWithCGPoint:CGPointMake(0.0, 1.0)];

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[animStart, animEnd];
    group.duration = 2.4;
    group.autoreverses = YES;
    group.repeatCount = HUGE_VALF;
    group.removedOnCompletion = NO;
    [grad addAnimation:group forKey:@"blackRedShimmer"];

    // Тонкая неоново-красная обводка контура
    CAShapeLayer *strokeLayer = [CAShapeLayer layer];
    strokeLayer.path = path.CGPath;
    strokeLayer.fillColor = [UIColor clearColor].CGColor;
    strokeLayer.strokeColor = [UIColor colorWithRed:0.95 green:0.15 blue:0.22 alpha:MIN(1.0, a + 0.25)].CGColor;
    strokeLayer.lineWidth = MAX(1.2, sqSize * 0.03);
    strokeLayer.lineJoin = kCALineJoinRound;

    [container addSublayer:grad];
    [container addSublayer:strokeLayer];
    return container;
}
static void drawArrowsCore(UIView *board, BOOL flipped) {
    if (!board || !board.window || !gCurrentArrows.count) return;
    CGRect bounds = board.bounds;
    CGFloat sqSize = bounds.size.width / 8.0;
    if (!gArrowLayers) gArrowLayers = [NSMutableArray array];
    for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
    [gArrowLayers removeAllObjects];

    for (NSDictionary *a in gCurrentArrows) {
         CALayer *layer = buildArrowLayer(a[@"move"], bounds, flipped,
                                              [a[@"eval"] doubleValue], [a[@"rank"] intValue]);
        if (layer) { [board.layer addSublayer:layer]; [gArrowLayers addObject:layer]; }

        NSString *label = a[@"label"];
        int fromSq = 0, toSq = 0;
        if (gShowEvalLabels && label.length && parseMoveUCI(a[@"move"], &fromSq, &toSq)) {
            CGPoint toPt = squareToPoint(toSq, bounds, flipped);
            CATextLayer *tl = [CATextLayer layer];
            tl.string = label;
            tl.fontSize = MAX(8.0, sqSize * 0.30);
            tl.alignmentMode = kCAAlignmentCenter;
            tl.foregroundColor = [UIColor whiteColor].CGColor;
            tl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6].CGColor;
            tl.cornerRadius = 3; tl.masksToBounds = YES;
            tl.contentsScale = [UIScreen mainScreen].scale;
            CGFloat lw = sqSize * 0.7, lh = sqSize * 0.36;
            tl.frame = CGRectMake(toPt.x - lw / 2, toPt.y - lh / 2, lw, lh);
            tl.zPosition = 10001;
            [board.layer addSublayer:tl]; [gArrowLayers addObject:tl];
        }
    }
}

static void reassertArrow(UIView *board);
static void drawArrowsOnBoard(NSArray *arrows, UIView *board, BOOL flipped) {
    dispatch_async(dispatch_get_main_queue(), ^{
        clearArrow();
        gCurrentArrows = [arrows copy];
        gArrowFlipped = flipped;
        drawArrowsCore(board, flipped);
        if (gArrowLayers.count)
            dbg([NSString stringWithFormat:@"arrows: %lu", (unsigned long)gArrowLayers.count]);

        for (double delay = 0.4; delay <= 2.0; delay += 0.5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ reassertArrow(board); });
        }
    });
}

static void reassertArrow(UIView *board) {
    if (!gCurrentArrows.count || !board || !board.window) return;
    CALayer *first = gArrowLayers.firstObject;
    if (first && first.superlayer == board.layer) return;
    drawArrowsCore(board, gArrowFlipped);
}

static void showSettingsMenu(void);

@interface CHAssistBtnHandler : NSObject
+ (void)floatBtnTapped;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp;
@end

@implementation CHAssistBtnHandler
+ (void)floatBtnTapped {
    if (gSkipNextTap) { gSkipNextTap = NO; return; }
    showSettingsMenu();
}
+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIView *container = btn.superview;
    CGPoint translation = [pan translationInView:container];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:container];
}
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    gSkipNextTap = YES;
    gEnabled = !gEnabled;
    savePrefs();
    if (!gEnabled) clearArrow();
    dbg([NSString stringWithFormat:@"quick toggle: %@", gEnabled ? @"ON" : @"OFF"]);
    showQualityToast(gEnabled ? @"▶ Assistant On" : @"⏸ Assistant Paused",
                     gEnabled ? CH_ACCENT : [UIColor systemRedColor]);
}
@end

static UIWindow *gBtnWin = nil;
static UIButton *gFloatBtn = nil;

static void setupFloatingButton(void) {
    if (gBtnWin) return;

    UIWindowScene *activeScene = nil;
    if (@available(iOS 13, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)sc;
                break;
            }
        }
    }

    if (@available(iOS 13, *)) {
        if (activeScene) gBtnWin = [[UIWindow alloc] initWithWindowScene:activeScene];
    }
    if (!gBtnWin) gBtnWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    gBtnWin.windowLevel = UIWindowLevelAlert + 2;
    gBtnWin.backgroundColor = [UIColor clearColor];
    gBtnWin.userInteractionEnabled = YES;
    gBtnWin.rootViewController = [[UIViewController alloc] init];
    gBtnWin.rootViewController.view.backgroundColor = [UIColor clearColor];

    gBtnWin.rootViewController.view.userInteractionEnabled = YES;

    CGFloat btnSize = 40;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat x = screenW - btnSize - 8;
    CGFloat y = screenH * 0.45;

    gFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatBtn.frame = CGRectMake(x, y, btnSize, btnSize);
    gFloatBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.04 blue:0.06 alpha:0.88];
    gFloatBtn.layer.cornerRadius = 14;
    gFloatBtn.layer.borderColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.20 alpha:0.95].CGColor;
    gFloatBtn.layer.borderWidth = 1;
 NSData *imgData = [[NSData alloc] initWithBase64EncodedString:@"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nYxQAzAFIE9aeB6Uc0AMx2p2KXBooAbgd6No607FGD2oAb2wKQADpTwDS4NAEYB70oGOO1Px2FAVqAP/2QAA/+EJY2h0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8APD94cGFja2V0IGJlZ2luPSLvu78iIGlkPSJXNU0wTXBDZWhpSHpyZVN6TlRjemtjOWQiPz4gPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iWE1QIENvcmUgNi4wLjAiPiA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiPiA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIiB4bWxuczp4bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtcDpDcmVhdG9yVG9vbD0iUGljYXNhIi8+IDwvcmRmOlJERj4gPC94OnhtcG1ldGE+ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPD94cGFja2V0IGVuZD0idyI/PgD/2wCEAAMCAgoICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoICAgICgoKCAgNDQoIDQcICggBAwQEBgUGCgYGCg0NCg0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDf/AABEIBAAEAAMBIgACEQEDEQH/xAAdAAEBAAEFAQEAAAAAAAAAAAAAAQIDBAUGCAcJ/8QAXRAAAgEDAQQGBAgICQgJAwMFAAECAwQRIQUSMUEGBwgTUWEiMnGBFCNCUpGh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" options:NSDataBase64DecodingIgnoreUnknownCharacters];
UIImage *customImg = [UIImage imageWithData:imgData];
[gFloatBtn setImage:customImg forState:UIControlStateNormal];
gFloatBtn.imageView.contentMode = UIViewContentModeScaleAspectFill;
gFloatBtn.clipsToBounds = YES;
    [gFloatBtn addTarget:[CHAssistBtnHandler class] action:@selector(floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[CHAssistBtnHandler class] action:@selector(handlePan:)];
    [gFloatBtn addGestureRecognizer:pan];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CHAssistBtnHandler class] action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [gFloatBtn addGestureRecognizer:lp];

    [gBtnWin.rootViewController.view addSubview:gFloatBtn];
    gBtnWin.hidden = NO;
    [gBtnWin makeKeyAndVisible];

    [[UIApplication sharedApplication].delegate.window makeKeyWindow];
}

%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self == gBtnWin) {

        CGPoint btnPoint = [gFloatBtn convertPoint:point fromView:self.rootViewController.view];
        if ([gFloatBtn pointInside:btnPoint withEvent:event]) {
            return gFloatBtn;
        }
        return nil;
    }
    return %orig;
}
%end

static UIWindow *gMenuWin = nil;

static UIWindow *menuWin(void) {
    if (gMenuWin) return gMenuWin;
    if (@available(iOS 13, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                gMenuWin = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)sc];
                break;
            }
        }
    }
    if (!gMenuWin) gMenuWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gMenuWin.windowLevel = UIWindowLevelAlert + 3;
    gMenuWin.rootViewController = [[UIViewController alloc] init];
    gMenuWin.backgroundColor = [UIColor clearColor];
    gMenuWin.hidden = YES;
    return gMenuWin;
}

static void hideMenu(void) {
    gMenuWin.hidden = YES;
    [[UIApplication sharedApplication].delegate.window makeKeyWindow];
}

static void showAC(UIAlertController *ac) {
    UIWindow *w = menuWin();
    w.hidden = NO;
    [w makeKeyAndVisible];
    UIViewController *r = w.rootViewController;
    if (r.presentedViewController)
        [r dismissViewControllerAnimated:NO completion:^{ [r presentViewController:ac animated:YES completion:nil]; }];
    else [r presentViewController:ac animated:YES completion:nil];
}

static UIView *findBoardArea(UIView *view, int depth);

static void showDebugLog(void) {
    NSString *logStr = gLog.count ? [gLog componentsJoinedByString:@"\n"] : @"No entries.";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Debug Log"
        message:logStr
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"📋 Copy Logs" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = logStr;
            hideMenu();
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *_) { [gLog removeAllObjects]; hideMenu(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];
    showAC(ac);
}

static void showCredits(void) {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Recrouser Dominate"
        message:@"Готов доминировать над детьми шалав?"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { hideMenu(); }]];
    showAC(ac);
}


#if 0
static void reopenSettings(void) {
    hideMenu();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showSettingsMenu(); });
}
#endif

static void redrawArrows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *b = gDrawBoard ?: gBoardView;
        if (b && b.window && gCurrentArrows.count) drawArrowsCore(b, gArrowFlipped);
    });
}

#if 0
static void showEloMenu(void) {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Set ELO"
        message:@"Higher = stronger but riskier. ⚠️ = above ~1500 (ban risk)."
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *levels = @[@400, @600, @800, @1000, @1200, @1400, @1600, @1800,
                        @2000, @2200, @2400, @2800, @3200, @3500];
    NSArray *names  = @[@"400 Novice", @"600 Beginner", @"800 Casual", @"1000 Improving",
                        @"1200 Intermediate", @"1400 Club", @"1600 Strong Club", @"1800 Expert",
                        @"2000 Candidate Master", @"2200 Master", @"2400 IM/GM",
                        @"2800 Super-GM", @"3200 Engine", @"3500 Max"];
    for (NSUInteger i = 0; i < levels.count; i++) {
        NSInteger lvl = [levels[i] integerValue];
        [ac addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"%@%@%@", names[i],
                             lvl > 1500 ? @" ⚠️" : @"", lvl == gElo ? @" ✓" : @""]
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *_) {
                gElo = lvl;
                savePrefs();
                dbg([NSString stringWithFormat:@"ELO set to %ld", (long)lvl]);
                if (lvl > 1500) {
                    UIAlertController *w = [UIAlertController
                        alertControllerWithTitle:@"⚠️ Ban Risk"
                        message:@"Playing above ~1500 strength is much easier for Chess.com's "
                                 "fair-play system to detect and greatly increases your risk of "
                                 "an account ban. Lower ELO is safer."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [w addAction:[UIAlertAction actionWithTitle:@"I understand"
                        style:UIAlertActionStyleDestructive
                        handler:^(UIAlertAction *_2) { hideMenu(); }]];
                    showAC(w);
                } else {
                    hideMenu();
                }
            }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}

static void showArrowStyleMenu(void) {
    NSString *opacityTxt = [NSString stringWithFormat:@"Opacity: %.0f%%", gArrowAlpha * 100];
    NSString *thickTxt   = gArrowThick < 0.85 ? @"Thickness: Thin" :
                           (gArrowThick > 1.2 ? @"Thickness: Thick" : @"Thickness: Normal");
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Arrow Style" message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"Color: %@", gArrowEvalColor ? @"By Eval" : @"Green"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gArrowEvalColor = !gArrowEvalColor; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:opacityTxt
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            CGFloat steps[] = {0.4, 0.55, 0.7, 0.85, 1.0};
            int idx = 0; for (int i = 0; i < 5; i++) if (gArrowAlpha >= steps[i] - 0.01) idx = i;
            gArrowAlpha = steps[(idx + 1) % 5]; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:thickTxt
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gArrowThick = gArrowThick < 0.85 ? 1.0 : (gArrowThick > 1.2 ? 0.7 : 1.4);
            savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"Eval Labels: %@", gShowEvalLabels ? @"On" : @"Off"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gShowEvalLabels = !gShowEvalLabels; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"‹ Back" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { reopenSettings(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}

static void showSettingsMenu(void) {
    NSString *accLine = @"";
    if (gTrackQuality && gAccCount > 0) {
        accLine = [NSString stringWithFormat:@"\nAccuracy: %.0f%% (%d moves)\n✓%d  ?!%d  ?%d  ??%d%@",
                   gAccSum / gAccCount, gAccCount, gQGood, gQInacc, gQMist, gQBlund,
                   gLastMoveQuality.length ? [@"\nLast: " stringByAppendingString:gLastMoveQuality] : @""];
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Chess Assistant"
        message:[NSString stringWithFormat:@"ELO: %ld | %@ | Depth: %ld\nPlaying: %@%@\n\nby @epicccccc",
                 (long)gElo, gEnabled ? @"ON" : @"OFF", (long)eloToDepth(gElo),
                 gMyColor == 0 ? @"White" : (gMyColor == 1 ? @"Black" : @"Unknown"), accLine]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"🎚 Set ELO (%ld)%@", (long)gElo,
                         gElo > 1500 ? @" ⚠️" : @""]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showEloMenu(); });
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"📊 Eval: %@", gShowWinPct ? @"Win %" : @"Centipawn"]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gShowWinPct = !gShowWinPct; savePrefs();
            dbg([NSString stringWithFormat:@"Eval display: %@", gShowWinPct ? @"win%" : @"cp"]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"➹ Arrows: %ld", (long)gArrowCount]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gArrowCount = (gArrowCount % 3) + 1;
            savePrefs();
            gLastFen = nil;
            dbg([NSString stringWithFormat:@"Arrows: %ld", (long)gArrowCount]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"🎨 Arrow Style"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"🎯 Move Analysis: %@", gTrackQuality ? @"On" : @"Off"]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gTrackQuality = !gTrackQuality; savePrefs();
            if (!gTrackQuality) resetAccuracy();
            dbg([NSString stringWithFormat:@"Move analysis: %@", gTrackQuality ? @"on" : @"off"]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:gEnabled ? @"⏸ Disable" : @"▶ Enable"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *_) {
            gEnabled = !gEnabled;
            savePrefs();
            if (!gEnabled) clearArrow();
            dbg([NSString stringWithFormat:@"Toggled: %@", gEnabled ? @"ON" : @"OFF"]);
            hideMenu();
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"📋 Debug Log"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDebugLog(); });
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Credits"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showCredits(); });
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Close"
        style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}
#endif


@interface CHPad : UILabel @end
@implementation CHPad
- (void)drawTextInRect:(CGRect)r {
    [super drawTextInRect:UIEdgeInsetsInsetRect(r, UIEdgeInsetsMake(3, 9, 3, 9))];
}
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + 18, s.height + 6);
}
@end

static const NSInteger kEloLevels[] = {400,600,800,1000,1200,1400,1600,1800,2000,2200,2400,2800,3200,3500};
static const int kEloCount = 14;
static NSString *ecoName(void) {
    if (!gUciSeq || !gUciSeq.length) return nil;
    static NSDictionary<NSString *, NSString *> *sTable = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTable = @{
            @"e2e4 e7e5":                                   @"Open Game",
            @"e2e4 e7e5 g1f3 b8c6 f1b5":                    @"Ruy Lopez",
            @"e2e4 e7e5 g1f3 b8c6 f1b5 a7a6":               @"Ruy Lopez, Closed",
            @"e2e4 e7e5 g1f3 b8c6 f1b5 g8f6":               @"Ruy Lopez, Berlin",
            @"e2e4 e7e5 g1f3 b8c6 f1c4":                    @"Italian Game",
            @"e2e4 e7e5 g1f3 b8c6 d2d4":                    @"Scotch Game",
            @"e2e4 e7e5 g1f3 g8f6":                         @"Petrov Defense",
            @"e2e4 e7e5 g1f3 f8c5":                         @"Giuoco Piano",
            @"e2e4 e7e5 b1c3":                              @"Vienna Game",
            @"e2e4 e7e5 f2f4":                              @"King's Gambit",
            @"e2e4 c7c5":                                   @"Sicilian Defense",
            @"e2e4 c7c5 c2c3":                              @"Sicilian, Alapin",
            @"e2e4 c7c5 b1c3":                              @"Sicilian, Closed",
            @"e2e4 c7c5 g2g3":                              @"Sicilian, Fianchetto",
            @"e2e4 c7c5 g1f3 b8c6":                         @"Sicilian, Old",
            @"e2e4 c7c5 g1f3 d7d6":                         @"Sicilian, Open",
            @"e2e4 c7c5 g1f3 e7e6":                         @"Sicilian, French",
            @"e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 g1d4 g8f6 b1c3 a7a6": @"Sicilian, Najdorf",
            @"e2e4 e7e6":                                   @"French Defense",
            @"e2e4 c7c6":                                   @"Caro-Kann Defense",
            @"e2e4 d7d6":                                   @"Pirc Defense",
            @"e2e4 d7d5":                                   @"Scandinavian Defense",
            @"e2e4 g8f6":                                   @"Alekhine Defense",
            @"d2d4 d7d5":                                   @"Closed Game",
            @"d2d4 d7d5 c2c4":                              @"Queen's Gambit",
            @"d2d4 d7d5 c2c4 e7e6":                         @"Queen's Gambit Declined",
            @"d2d4 d7d5 c2c4 c7c6":                         @"Slav Defense",
            @"d2d4 d7d5 c2c4 d5c4":                         @"Queen's Gambit Accepted",
            @"d2d4 g8f6":                                   @"Indian Defense",
            @"d2d4 g8f6 c2c4 e7e6":                         @"Indian, Queen's",
            @"d2d4 g8f6 c2c4 g7g6":                         @"King's Indian / Grünfeld",
            @"d2d4 g8f6 g1f3 g7g6":                         @"King's Indian Attack",
            @"d2d4 f7f5":                                   @"Dutch Defense",
            @"c2c4":                                        @"English Opening",
            @"c2c4 e7e5":                                   @"English, Reversed Sicilian",
            @"c2c4 g8f6":                                   @"English, Anglo-Indian",
            @"g1f3 d7d5 c2c4":                              @"Réti Opening",
            @"f2f4":                                        @"Bird's Opening",
        };
    });
    NSString *seq = [gUciSeq stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    __block NSString *best = nil;
    __block NSUInteger bestLen = 0;
    [sTable enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        if ([seq hasPrefix:k] && k.length > bestLen) { best = v; bestLen = k.length; }
    }];
    return best;
}

static NSString *eloTierName(NSInteger e) {    if (e < 600)  return @"Novice";        if (e < 800)  return @"Beginner";
    if (e < 1000) return @"Casual";        if (e < 1200) return @"Improving";
    if (e < 1400) return @"Intermediate";  if (e < 1600) return @"Club";
    if (e < 1800) return @"Strong Club";   if (e < 2000) return @"Expert";
    if (e < 2200) return @"Cand. Master";  if (e < 2400) return @"Master";
    if (e < 2800) return @"IM / GM";       if (e < 3200) return @"Super-GM";
    if (e < 3500) return @"Engine";        return @"Maximum";
}
static const NSInteger kMaiaLevels[] = {600,700,800,900,1000,1100,1200,1300,1400,1500,1600,1700,
                                        1800,1900,2000,2100,2200,2300,2400,2500,2600,2700,2800,2900};
static const int kMaiaLevelCount = 24;

static const NSInteger *activeEloLevels(int *outCount) {
    if (gUseMaia) { *outCount = kMaiaLevelCount; return kMaiaLevels; }
    *outCount = kEloCount; return kEloLevels;
}
static int activeEloNearestIndex(NSInteger e) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    int best = 0; long bd = LONG_MAX;
    for (int i = 0; i < c; i++) { long d = labs((long)(l[i] - e)); if (d < bd) { bd = d; best = i; } }
    return best;
}
__attribute__((unused)) static NSInteger activeEloForIndex(int i) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    if (i < 0) i = 0; if (i >= c) i = c - 1;
    return l[i];
}
static void clampGeloToActiveRange(void) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    if (gElo < l[0]) gElo = l[0];
    if (gElo > l[c-1]) gElo = l[c-1];
}

@interface CHSettingsPanel : UIView {
    UIView      *_card;
    UIStackView *_stack;
    UIScrollView *_scroll;
    UILabel     *_eloValue;
    UILabel     *_eloTier;
    UILabel     *_apDelayValue;
    UILabel     *_apJitterValue;
    UILabel     *_apSecondPctValue;
    UILabel     *_opValue;
}
@end
@implementation CHSettingsPanel

+ (void)show {
    UIWindow *w = menuWin();
    w.hidden = NO; [w makeKeyAndVisible];
    UIView *root = w.rootViewController.view;
    for (UIView *v in [root.subviews copy])
        if ([v isKindOfClass:[CHSettingsPanel class]]) [v removeFromSuperview];
    CHSettingsPanel *p = [[CHSettingsPanel alloc] initWithFrame:root.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:p];
    [p build];
    [p animateIn];
  
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTap:)];
        t.cancelsTouchesInView = NO;
        [self addGestureRecognizer:t];
    }
    return self;
}

- (void)bgTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (_card && CGRectContainsPoint(_card.frame, p)) return;
    [self animateOut];
}

- (UILabel *)lbl:(NSString *)t size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.text = t; l.textColor = c; l.font = [UIFont systemFontOfSize:s weight:w];
    l.numberOfLines = 1;
    NSLayoutConstraint *h = [l.heightAnchor constraintGreaterThanOrEqualToConstant:ceil(s * 1.35)];
    h.priority = 999; h.active = YES;
    return l;
}

- (UIView *)sep {
    UIView *s = [[UIView alloc] init];
    s.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [s.heightAnchor constraintEqualToConstant:1].active = YES;
    return s;
}

- (UIView *)sliderRow:(UISlider *)s {
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *h = [s.heightAnchor constraintEqualToConstant:32];
    h.priority = 999; h.active = YES;
    UIView *box = [[UIView alloc] init];
    [box addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:box.topAnchor constant:2],
        [s.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2],
        [s.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:box.trailingAnchor]]];
    return box;
}

- (UILabel *)sectionLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t.uppercaseString;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:l.text attributes:@{
        NSFontAttributeName: l.font,
        NSForegroundColorAttributeName: l.textColor,
        NSKernAttributeName: @1.2
    }];
    l.attributedText = attr;
    NSLayoutConstraint *h = [l.heightAnchor constraintGreaterThanOrEqualToConstant:16];
    h.priority = 999; h.active = YES;
    return l;
}

- (UIView *)group:(UIView *)inner {
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    box.layer.cornerRadius = 14;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:box.topAnchor constant:12],
        [inner.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-12],
        [inner.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14]]];
    return box;
}

- (UIView *)rowTitle:(NSString *)t control:(UIView *)ctrl {
    UILabel *l = [self lbl:t size:15 weight:UIFontWeightMedium color:UIColor.whiteColor];
    NSMutableArray *arr = [NSMutableArray array];
    if (ctrl) {
        ctrl.translatesAutoresizingMaskIntoConstraints = NO;
        [arr addObject:l];
        [arr addObject:ctrl];
    } else {
        [arr addObject:l];
    }
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:arr];
    h.axis = UILayoutConstraintAxisHorizontal; h.alignment = UIStackViewAlignmentCenter;
    h.distribution = UIStackViewDistributionFill;
    [l setContentHuggingPriority:250 forAxis:UILayoutConstraintAxisHorizontal];
    if (ctrl) {
        [ctrl setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        [ctrl setContentCompressionResistancePriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        if ([ctrl isKindOfClass:[UISlider class]]) [ctrl.widthAnchor constraintEqualToConstant:150].active = YES;
    }
    return h;
}

- (void)styleSeg:(UISegmentedControl *)s {
    if (@available(iOS 13, *)) {
        s.selectedSegmentTintColor = CH_ACCENT;
        s.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
        [s setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
        [s setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateSelected];
    }
    [s setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
}

- (UISwitch *)switchOn:(BOOL)on sel:(SEL)sel {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on; sw.onTintColor = CH_ACCENT;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (CHPad *)chip:(NSString *)t color:(UIColor *)col {
    CHPad *p = [[CHPad alloc] init];
    p.text = t; p.font = [UIFont boldSystemFontOfSize:13];
    p.textColor = UIColor.whiteColor; p.textAlignment = NSTextAlignmentCenter;
    p.backgroundColor = [col colorWithAlphaComponent:0.9];
    p.layer.cornerRadius = 8; p.clipsToBounds = YES;
    return p;
}

- (UIButton *)bigBtn:(NSString *)t color:(UIColor *)col sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = col; b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)smallBtn:(NSString *)t sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithRed:0.45 green:0.06 blue:0.10 alpha:0.85];
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)statsCard {
    UIView *c = [[UIView alloc] init];
    c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    c.layer.cornerRadius = 14;
    UIView *content;
    if (!(gTrackQuality && gAccCount > 0)) {
        content = [self lbl:(gTrackQuality ? @"Dominating slaves is greatness."
                                           : @"Move Analysis is off — turn it on below to grade your moves.")
                       size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
    } else {
        double acc = gAccSum / gAccCount;
        UIColor *accCol = acc >= 90 ? CH_ACCENT : (acc >= 75 ? [UIColor systemYellowColor] : [UIColor systemOrangeColor]);
        UILabel *big = [self lbl:[NSString stringWithFormat:@"%.0f%%", acc] size:40 weight:UIFontWeightHeavy color:accCol];
        UILabel *cap = [self lbl:[NSString stringWithFormat:@"Accuracy · %d moves", gAccCount] size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
        UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[big, cap]];
        top.axis = UILayoutConstraintAxisVertical; top.alignment = UIStackViewAlignmentLeading;

        UIStackView *breakdown = [[UIStackView alloc] init];
        breakdown.axis = UILayoutConstraintAxisVertical; breakdown.spacing = 6;
        for (int i = 0; i < Q_COUNT; i++) {
            CHPad *sym = [self chip:qSymbol(i) color:qColor(i)];
            [sym setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *name = [self lbl:qName(i) size:13 weight:UIFontWeightMedium color:UIColor.whiteColor];
            UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[sym, name]];
            left.axis = UILayoutConstraintAxisHorizontal; left.spacing = 8; left.alignment = UIStackViewAlignmentCenter;
            [left setContentHuggingPriority:250 forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *cnt = [self lbl:[NSString stringWithFormat:@"%d  (%.0f%%)", gQ[i],
                                      gAccCount ? gQ[i] * 100.0 / gAccCount : 0]
                                 size:13 weight:UIFontWeightSemibold color:qColor(i)];
            cnt.textAlignment = NSTextAlignmentRight;
            [cnt setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
            UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, cnt]];
            row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionFill;
            [breakdown addArrangedSubview:row];
        }

        NSMutableArray *parts = [@[top, breakdown] mutableCopy];
        if (gLastMoveQuality.length)
            [parts addObject:[self lbl:[@"Last move: " stringByAppendingString:gLastMoveQuality]
                                   size:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.75 alpha:1]]];
        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:parts];
        col.axis = UILayoutConstraintAxisVertical; col.spacing = 12;
        content = col;
    }
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:c.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-14],
        [content.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14]]];
    return c;
}

- (void)build {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
    card.contentView.backgroundColor = [UIColor colorWithRed:0.05 green:0.02 blue:0.03 alpha:0.92];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 22;
    card.layer.masksToBounds = YES;
    [self addSubview:card];
    _card = card;

    // Переливающаяся черно-красная неоновая рамка
    CAGradientLayer *borderGrad = [CAGradientLayer layer];
    borderGrad.frame = CGRectMake(0, 0, 356, 410);
    borderGrad.colors = @[
        (id)[UIColor colorWithRed:0.95 green:0.10 blue:0.18 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.02 blue:0.03 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.85 green:0.08 blue:0.15 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.06 alpha:1.0].CGColor
    ];
    borderGrad.locations = @[@0.0, @0.35, @0.7, @1.0];
    borderGrad.startPoint = CGPointMake(0, 0);
    borderGrad.endPoint   = CGPointMake(1, 1);

    CAShapeLayer *borderMask = [CAShapeLayer layer];
    borderMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, 356, 410), 1.0, 1.0) cornerRadius:22].CGPath;
    borderMask.fillColor = [UIColor clearColor].CGColor;
    borderMask.strokeColor = [UIColor blackColor].CGColor;
    borderMask.lineWidth = 2.0;
    borderGrad.mask = borderMask;

    CABasicAnimation *bAnim1 = [CABasicAnimation animationWithKeyPath:@"startPoint"];
    bAnim1.fromValue = [NSValue valueWithCGPoint:CGPointMake(0, 0)];
    bAnim1.toValue   = [NSValue valueWithCGPoint:CGPointMake(1, 0)];
    CABasicAnimation *bAnim2 = [CABasicAnimation animationWithKeyPath:@"endPoint"];
    bAnim2.fromValue = [NSValue valueWithCGPoint:CGPointMake(1, 1)];
    bAnim2.toValue   = [NSValue valueWithCGPoint:CGPointMake(0, 1)];
    CAAnimationGroup *bGroup = [CAAnimationGroup animation];
    bGroup.animations = @[bAnim1, bAnim2];
    bGroup.duration = 2.8;
    bGroup.autoreverses = YES;
    bGroup.repeatCount = HUGE_VALF;
    bGroup.removedOnCompletion = NO;
    [borderGrad addAnimation:bGroup forKey:@"cardBorderShimmer"];
    [card.layer addSublayer:borderGrad];

    UIView *grab = [[UIView alloc] init];
    grab.translatesAutoresizingMaskIntoConstraints = NO;
    grab.backgroundColor = [UIColor colorWithRed:0.90 green:0.15 blue:0.22 alpha:0.55];
    grab.layer.cornerRadius = 2.5;
    [card.contentView addSubview:grab];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [card.contentView addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    _stack = stack;
    _scroll = scroll;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:356.0],
        [card.heightAnchor constraintEqualToConstant:410.0],

        [grab.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:8],
        [grab.centerXAnchor constraintEqualToAnchor:card.contentView.centerXAnchor],
        [grab.widthAnchor constraintEqualToConstant:42],
        [grab.heightAnchor constraintEqualToConstant:4],

        [scroll.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:18],
        [scroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-14]
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardPan:)];
    [card addGestureRecognizer:pan];

    [self populate];
}


- (void)handleCardPan:(UIPanGestureRecognizer *)pan {
    UIView *target = pan.view;
    CGPoint translation = [pan translationInView:self];
    target.center = CGPointMake(target.center.x + translation.x, target.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self];
}


- (void)populate {
    @try {
        for (UIView *v in [_stack.arrangedSubviews copy]) { [_stack removeArrangedSubview:v]; [v removeFromSuperview]; }

        // Верхняя шапка с переливающимся черно-красным акцентом
        UIView *headerBox = [[UIView alloc] init];
        headerBox.backgroundColor = [UIColor colorWithRed:0.10 green:0.03 blue:0.04 alpha:0.85];
        headerBox.layer.cornerRadius = 14;
        headerBox.layer.borderWidth = 1.0;
        headerBox.layer.borderColor = [UIColor colorWithRed:0.88 green:0.12 blue:0.18 alpha:0.45].CGColor;

        UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
        [x setTitle:@"✕" forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [x setTitleColor:[UIColor colorWithWhite:0.85 alpha:1] forState:UIControlStateNormal];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [x setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];

        UILabel *titleLbl = [self lbl:@"Recrouser Dominate" size:19 weight:UIFontWeightBold color:[UIColor whiteColor]];
        UIStackView *hdr = [[UIStackView alloc] initWithArrangedSubviews:@[titleLbl, x]];
        hdr.axis = UILayoutConstraintAxisHorizontal;
        hdr.alignment = UIStackViewAlignmentCenter;

        NSString *sub = [NSString stringWithFormat:@"%@ • Depth %ld • %@ • %@",
            gEnabled ? @"Active" : @"Paused",
            (long)eloToDepth(gElo),
            gUseMaia ? @"Maia AI" : @"Stockfish 18",
            gMyColor == 0 ? @"White" : (gMyColor == 1 ? @"Black" : @"Auto")];
        UILabel *subLbl = [self lbl:sub size:11 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.95 green:0.25 blue:0.30 alpha:1.0]];

        UIStackView *hdrCol = [[UIStackView alloc] initWithArrangedSubviews:@[hdr, subLbl]];
        hdrCol.axis = UILayoutConstraintAxisVertical;
        hdrCol.spacing = 4;
        hdrCol.translatesAutoresizingMaskIntoConstraints = NO;
        [headerBox addSubview:hdrCol];
        [NSLayoutConstraint activateConstraints:@[
            [hdrCol.topAnchor constraintEqualToAnchor:headerBox.topAnchor constant:10],
            [hdrCol.bottomAnchor constraintEqualToAnchor:headerBox.bottomAnchor constant:-10],
            [hdrCol.leadingAnchor constraintEqualToAnchor:headerBox.leadingAnchor constant:12],
            [hdrCol.trailingAnchor constraintEqualToAnchor:headerBox.trailingAnchor constant:-12]
        ]];
        [_stack addArrangedSubview:headerBox];

        // Панель навигации (4 логические вкладки в стиле Xentrix)
        UISegmentedControl *tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"Engine", @"Visual", @"Stats", @"Misc"]];
        tabSeg.selectedSegmentIndex = 0;
        [self styleSeg:tabSeg];
        [tabSeg addTarget:self action:@selector(onTabSwitch:) forControlEvents:UIControlEventValueChanged];
        [_stack addArrangedSubview:tabSeg];

        // 4 контейнера вкладок
        UIStackView *engineTab = [[UIStackView alloc] init];
        engineTab.axis = UILayoutConstraintAxisVertical; engineTab.spacing = 10;

        UIStackView *visualTab = [[UIStackView alloc] init];
        visualTab.axis = UILayoutConstraintAxisVertical; visualTab.spacing = 10; visualTab.hidden = YES;

        UIStackView *statsTab = [[UIStackView alloc] init];
        statsTab.axis = UILayoutConstraintAxisVertical; statsTab.spacing = 10; statsTab.hidden = YES;

        UIStackView *miscTab = [[UIStackView alloc] init];
        miscTab.axis = UILayoutConstraintAxisVertical; miscTab.spacing = 10; miscTab.hidden = YES;

        // ==================== TAB 1: ENGINE & AUTO PLAY ====================
        [engineTab addArrangedSubview:[self sectionLabel:@"Engine Core"]];
        int eloCnt = 0; const NSInteger *eloLvls = activeEloLevels(&eloCnt);
        UISegmentedControl *engSeg = [[UISegmentedControl alloc] initWithItems:@[@"SF18", @"MAIA"]];
        engSeg.selectedSegmentIndex = gUseMaia ? 1 : 0;
        [self styleSeg:engSeg];
        [engSeg addTarget:self action:@selector(engSeg:) forControlEvents:UIControlEventValueChanged];

        _eloValue = [self lbl:[NSString stringWithFormat:@"%ld", (long)gElo] size:15 weight:UIFontWeightBold color:CH_ACCENT];
        NSString *tierText = gUseMaia
            ? [NSString stringWithFormat:@"%@ • tuned for Maia (%ld–%ld)", eloTierName(gElo), (long)eloLvls[0], (long)eloLvls[eloCnt - 1]]
            : eloTierName(gElo);
        _eloTier = [self lbl:tierText size:11 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.65 alpha:1.0]];
        [_eloValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *elo = [[UISlider alloc] init];
        elo.minimumValue = 0; elo.maximumValue = eloCnt - 1; elo.value = activeEloNearestIndex(gElo);
        elo.minimumTrackTintColor = CH_ACCENT;
        [elo addTarget:self action:@selector(eloSlide:) forControlEvents:UIControlEventValueChanged];
        [elo addTarget:self action:@selector(eloDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        NSString *strengthTitle = gUseMaia ? @"Strength (Human)" : @"Strength (ELO)";
        UIStackView *eloHdr = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self lbl:strengthTitle size:14 weight:UIFontWeightMedium color:[UIColor whiteColor]], _eloValue]];
        eloHdr.axis = UILayoutConstraintAxisHorizontal; eloHdr.distribution = UIStackViewDistributionFill;
        UIStackView *eloCol = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self rowTitle:@"Engine" control:engSeg], [self sep],
            eloHdr, [self sliderRow:elo], _eloTier]];
        eloCol.axis = UILayoutConstraintAxisVertical; eloCol.spacing = 8;
        [engineTab addArrangedSubview:[self group:eloCol]];

        [engineTab addArrangedSubview:[self sectionLabel:@"Auto Play"]];
        _apDelayValue = [self lbl:[NSString stringWithFormat:@"%.1fs", gAutoPlayDelay] size:14 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apDelayValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apDelay = [[UISlider alloc] init];
        apDelay.minimumValue = 0.0; apDelay.maximumValue = 5.0;
        apDelay.value = gAutoPlayDelay; apDelay.minimumTrackTintColor = CH_ACCENT;
        [apDelay addTarget:self action:@selector(apDelaySlide:) forControlEvents:UIControlEventValueChanged];
        [apDelay addTarget:self action:@selector(apDelayDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        _apJitterValue = [self lbl:[NSString stringWithFormat:@"±%.1fs", gAutoPlayJitterRange] size:14 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apJitterValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apJitter = [[UISlider alloc] init];
        apJitter.minimumValue = 0.0; apJitter.maximumValue = 2.0;
        apJitter.value = gAutoPlayJitterRange; apJitter.minimumTrackTintColor = CH_ACCENT;
        [apJitter addTarget:self action:@selector(apJitterSlide:) forControlEvents:UIControlEventValueChanged];
        [apJitter addTarget:self action:@selector(apJitterDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        _apSecondPctValue = [self lbl:[NSString stringWithFormat:@"%ld%%", (long)gAutoPlaySecondBestPct] size:14 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apSecondPctValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apSecondPct = [[UISlider alloc] init];
        apSecondPct.minimumValue = 0.0; apSecondPct.maximumValue = 50.0;
        apSecondPct.value = gAutoPlaySecondBestPct; apSecondPct.minimumTrackTintColor = CH_ACCENT;
        [apSecondPct addTarget:self action:@selector(apSecondPctSlide:) forControlEvents:UIControlEventValueChanged];
        [apSecondPct addTarget:self action:@selector(apSecondPctDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        UIStackView *apCol = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self rowTitle:@"Auto Play" control:[self switchOn:gAutoPlay sel:@selector(swAutoPlay:)]],
            [self sep],
            [self rowTitle:@"Move Delay" control:_apDelayValue],
            [self sliderRow:apDelay],
            [self sep],
            [self rowTitle:@"Jitter" control:[self switchOn:gAutoPlayJitterEnabled sel:@selector(swAutoJitter:)]],
            [self rowTitle:@"Jitter Range" control:_apJitterValue],
            [self sliderRow:apJitter],
            [self sep],
            [self rowTitle:@"2nd Move Chance" control:[self switchOn:gAutoPlaySecondBest sel:@selector(swAutoSecondBest:)]],
            [self rowTitle:@"2nd Move %" control:_apSecondPctValue],
            [self sliderRow:apSecondPct]
        ]];
        apCol.axis = UILayoutConstraintAxisVertical; apCol.spacing = 8;
        [engineTab addArrangedSubview:[self group:apCol]];

        // ==================== TAB 2: VISUAL & ARROWS ====================
        [visualTab addArrangedSubview:[self sectionLabel:@"Arrows & Shimmer"]];
        UISegmentedControl *evalSeg = [[UISegmentedControl alloc] initWithItems:@[@"Centipawn", @"Win %"]];
        evalSeg.selectedSegmentIndex = gShowWinPct ? 1 : 0; [self styleSeg:evalSeg];
        [evalSeg addTarget:self action:@selector(evalSeg:) forControlEvents:UIControlEventValueChanged];
        UISegmentedControl *arrSeg = [[UISegmentedControl alloc] initWithItems:@[@"1", @"2", @"3"]];
        arrSeg.selectedSegmentIndex = MIN(2, MAX(0, (int)gArrowCount - 1)); [self styleSeg:arrSeg];
        [arrSeg addTarget:self action:@selector(arrSeg:) forControlEvents:UIControlEventValueChanged];
        UISegmentedControl *thickSeg = [[UISegmentedControl alloc] initWithItems:@[@"Thin", @"Med", @"Thick"]];
thickSeg.selectedSegmentIndex = gArrowThick < 0.85 ? 0 : (gArrowThick > 1.2 ? 2 : 1); [self styleSeg:thickSeg];
[thickSeg addTarget:self action:@selector(thickSeg:) forControlEvents:UIControlEventValueChanged];
_opValue = [self lbl:[NSString stringWithFormat:@"%d%%", (int)round(gArrowAlpha * 100)] size:14 weight:UIFontWeightSemibold color:CH_ACCENT];
[_opValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
UISlider *op = [[UISlider alloc] init];
op.minimumValue = 0.3; op.maximumValue = 1.0; op.value = gArrowAlpha; op.minimumTrackTintColor = CH_ACCENT;
[op addTarget:self action:@selector(opSlide:) forControlEvents:UIControlEventValueChanged];
UIStackView *dispCol = [[UIStackView alloc] initWithArrangedSubviews:@[
[self rowTitle:@"Evaluation" control:evalSeg], [self sep],
[self rowTitle:@"Arrows Count" control:arrSeg], [self sep],
[self rowTitle:@"Thickness" control:thickSeg], [self sep],
[self rowTitle:@"Opacity" control:_opValue], [self sliderRow:op], [self sep],
[self rowTitle:@"Eval Bar" control:[self switchOn:gShowEvalBar sel:@selector(swEvalBar:)]], [self sep],
[self rowTitle:@"Eval Labels" control:[self switchOn:gShowEvalLabels sel:@selector(swLabels:)]], [self sep],
[self rowTitle:@"Shimmer Mode" control:[self switchOn:gArrowEvalColor sel:@selector(swColor:)]]
]];
dispCol.axis = UILayoutConstraintAxisVertical; dispCol.spacing = 8;
[visualTab addArrangedSubview:[self group:dispCol]];
// ==================== TAB 3: STATS & ANALYSIS ====================
[statsTab addArrangedSubview:[self sectionLabel:@"Match Accuracy"]];
NSString *eco = ecoName();
if (eco.length) {
UILabel *ecoLbl = [self lbl:[NSString stringWithFormat:@"Opening: %@", eco] size:12 weight:UIFontWeightSemibold color:[UIColor colorWithRed:0.95 green:0.35 blue:0.40 alpha:1.0]];
[statsTab addArrangedSubview:ecoLbl];
}
[statsTab addArrangedSubview:[self statsCard]];
UIStackView *anaCol = [[UIStackView alloc] initWithArrangedSubviews:@[
[self rowTitle:@"Move Analysis" control:[self switchOn:gTrackQuality sel:@selector(swAnalysis:)]]
]];
anaCol.axis = UILayoutConstraintAxisVertical;
[statsTab addArrangedSubview:[self group:anaCol]];
// ==================== TAB 4: CONTROLS & CREDITS ====================
[miscTab addArrangedSubview:[self sectionLabel:@"Quick Actions"]];
NSString *pauseTitle = gEnabled ? @"Pause Assistant" : @"Resume Assistant";
UIColor *pauseColor = gEnabled ? CH_ACCENT : [UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:1.0];
[miscTab addArrangedSubview:[self bigBtn:pauseTitle color:pauseColor sel:@selector(enableTap)]];
[miscTab addArrangedSubview:[self smallBtn:@"⚡ Preferred Settings (Ban-Safe)" sel:@selector(preferredTap)]];
UIStackView *copyRow = [[UIStackView alloc] initWithArrangedSubviews:@[
[self smallBtn:@"Copy FEN" sel:@selector(copyFenTap)],
[self smallBtn:@"Copy PGN" sel:@selector(pgnTap)]
]];
copyRow.axis = UILayoutConstraintAxisHorizontal; copyRow.spacing = 8; copyRow.distribution = UIStackViewDistributionFillEqually;
[miscTab addArrangedSubview:copyRow];
[miscTab addArrangedSubview:[self sectionLabel:@"Credits"]];
UILabel *tgLbl = [self lbl:@"Telegram: t.me/recrouser" size:13 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
UILabel *ytLbl = [self lbl:@"Seth & recrouser owned" size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.75 alpha:1.0]];
ytLbl.numberOfLines = 0;
UIStackView *credCol = [[UIStackView alloc] initWithArrangedSubviews:@[tgLbl, [self sep], ytLbl]];
credCol.axis = UILayoutConstraintAxisVertical; credCol.spacing = 8;
[miscTab addArrangedSubview:[self group:credCol]];
[_stack addArrangedSubview:engineTab];
[_stack addArrangedSubview:visualTab];
[_stack addArrangedSubview:statsTab];
[_stack addArrangedSubview:miscTab];
objc_setAssociatedObject(self, "engineTab", engineTab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
objc_setAssociatedObject(self, "visualTab", visualTab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
objc_setAssociatedObject(self, "statsTab", statsTab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
objc_setAssociatedObject(self, "miscTab", miscTab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
[_scroll setContentOffset:CGPointZero];
} @catch (NSException *e) {
dbg([NSString stringWithFormat:@"PANEL ERR: %@ - %@", e.name, e.reason]);
}
}
- (void)onTabSwitch:(UISegmentedControl *)seg { NSArray *keys = @[@"engineTab", @"visualTab", @"statsTab", @"miscTab"]; NSInteger idx = seg.selectedSegmentIndex; for (NSInteger i = 0; i < 4; i++) { UIView *tab = objc_getAssociatedObject(self, [keys[i] UTF8String]); if (i == idx) { tab.alpha = 0.0; tab.hidden = NO; tab.transform = CGAffineTransformMakeTranslation(0, 6); [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ tab.alpha = 1.0; tab.transform = CGAffineTransformIdentity; } completion:nil]; } else { tab.hidden = YES; } } [_scroll setContentOffset:CGPointZero animated:YES]; }

- (void)evalSeg:(UISegmentedControl *)s { gShowWinPct = (s.selectedSegmentIndex == 1); savePrefs(); redrawArrows(); }
- (void)arrSeg:(UISegmentedControl *)s { gArrowCount = s.selectedSegmentIndex + 1; savePrefs(); gLastFen = nil; }
- (void)thickSeg:(UISegmentedControl *)s {
    gArrowThick = s.selectedSegmentIndex == 0 ? 0.7 : (s.selectedSegmentIndex == 2 ? 1.4 : 1.0);
    savePrefs(); redrawArrows();
}
- (void)swEvalBar:(UISwitch *)s {
    gShowEvalBar = s.on; savePrefs();
    if (!gShowEvalBar) removeEvalBar(); else updateEvalBar();
    dbg([NSString stringWithFormat:@"eval bar: %@", gShowEvalBar ? @"ON" : @"OFF"]);
}
- (void)opSlide:(UISlider *)s {
    gArrowAlpha = s.value; savePrefs(); redrawArrows();
    _opValue.text = [NSString stringWithFormat:@"%d%%", (int)round(s.value * 100)];
}
- (void)swAnalysis:(UISwitch *)s { gTrackQuality = s.on; savePrefs(); if (!s.on) resetAccuracy(); [self populate]; }
- (void)swLabels:(UISwitch *)s { gShowEvalLabels = s.on; savePrefs(); redrawArrows(); }
- (void)swColor:(UISwitch *)s { gArrowEvalColor = s.on; savePrefs(); redrawArrows(); }
- (void)engSeg:(UISegmentedControl *)s {
    gUseMaia = (s.selectedSegmentIndex == 1);
    clampGeloToActiveRange();
    savePrefs(); gLastFen = nil;
    if (gUseMaia) ensureMaiaLoaded();
    dbg([NSString stringWithFormat:@"engine: %@ — strength range %@", gUseMaia ? @"MAIA" : @"SF18",
         gUseMaia ? @"900–2000 (human-like)" : @"400–3500"]);
    [self populate];
}
- (void)eloSlide:(UISlider *)s {
    int c = 0;
    const NSInteger *lvls = activeEloLevels(&c);
    int idx = (int)lround(s.value);
    if (idx < 0) idx = 0;
    if (idx >= c) idx = c - 1;
    s.value = (float)idx;
    NSInteger val = lvls[idx];
    _eloValue.text = [NSString stringWithFormat:@"%ld", (long)val];
    _eloTier.text = gUseMaia
        ? [NSString stringWithFormat:@"%@ • tuned for Maia (%ld–%ld)", eloTierName(val), (long)lvls[0], (long)lvls[c - 1]]
        : eloTierName(val);
}

- (void)eloDone:(UISlider *)s {
    int c = 0;
    const NSInteger *lvls = activeEloLevels(&c);
    int idx = (int)lround(s.value);
    if (idx < 0) idx = 0;
    if (idx >= c) idx = c - 1;
    gElo = lvls[idx];
    savePrefs();
    gLastFen = nil;
    dbg([NSString stringWithFormat:@"ELO set to %ld", (long)gElo]);
}

- (void)swAutoPlay:(UISwitch *)s {
    gAutoPlay = s.on; savePrefs();
    dbg([NSString stringWithFormat:@"Auto play: %@", gAutoPlay ? @"ON" : @"OFF"]);
    if (!gAutoPlay) gLastAutoPlayed = nil;
}
- (void)swAutoJitter:(UISwitch *)s {
    gAutoPlayJitterEnabled = s.on;
    savePrefs();
}
- (void)swAutoSecondBest:(UISwitch *)s {
    gAutoPlaySecondBest = s.on;
    savePrefs();
}
- (void)apDelaySlide:(UISlider *)s {
    double v = round(s.value * 10.0) / 10.0; s.value = v;
    _apDelayValue.text = [NSString stringWithFormat:@"%.1fs", v];
}
- (void)apDelayDone:(UISlider *)s {
    gAutoPlayDelay = round(s.value * 10.0) / 10.0;
    savePrefs();
    dbg([NSString stringWithFormat:@"Auto play delay: %.1fs", gAutoPlayDelay]);
}
- (void)apJitterSlide:(UISlider *)s {
    double v = round(s.value * 10.0) / 10.0; s.value = v;
    _apJitterValue.text = [NSString stringWithFormat:@"±%.1fs", v];
}
- (void)apJitterDone:(UISlider *)s {
    gAutoPlayJitterRange = round(s.value * 10.0) / 10.0;
    if (gAutoPlayJitterRange < 0) gAutoPlayJitterRange = 0;
    if (gAutoPlayJitterRange > 2.0) gAutoPlayJitterRange = 2.0;
    savePrefs();
}
- (void)apSecondPctSlide:(UISlider *)s {
    NSInteger v = (NSInteger)lround(s.value);
    if (v < 0) v = 0;
    if (v > 50) v = 50;
    s.value = (float)v;
    _apSecondPctValue.text = [NSString stringWithFormat:@"%ld%%", (long)v];
}
- (void)apSecondPctDone:(UISlider *)s {
    NSInteger v = (NSInteger)lround(s.value);
    if (v < 0) v = 0;
    if (v > 50) v = 50;
    gAutoPlaySecondBestPct = v;
    savePrefs();
}
- (void)pgnTap {
    NSString *pgn = buildPGN();
    if (!pgn.length) {
        showQualityToast(@"No game moves yet", [UIColor systemOrangeColor]);
        return;
    }
    [UIPasteboard generalPasteboard].string = pgn;
    showQualityToast(@"📜 PGN copied", CH_ACCENT);
}
- (void)copyFenTap {
    NSString *fen = gLastFen;
    if (!fen.length) {
        showQualityToast(@"No position yet", [UIColor systemOrangeColor]);
        return;
    }
    [UIPasteboard generalPasteboard].string = fen;
    showQualityToast(@"FEN copied", CH_ACCENT);
    dbg([NSString stringWithFormat:@"copied FEN: %@", fen]);
}
- (void)preferredTap {
    gArrowCount   = 3;
    gArrowAlpha   = 0.3;
    gShowWinPct   = YES;
    gArrowThick   = 0.7;
    gUseMaia      = YES;
    gAutoPlay     = NO;
    gAutoPlayJitterEnabled = NO;
    gAutoPlayJitterRange = 1.0;
    gAutoPlaySecondBest = NO;
    gAutoPlaySecondBestPct = 10;
    gElo          = 1000;
    gLastFen      = nil;
    gLastAutoPlayed = nil;
    savePrefs();
    resetAccuracy();
    dbg(@"preset: preferred (ban-safe) applied");
    showQualityToast(@"⚡ Ban-Safe Preset", CH_ACCENT);
    [self populate];
}
- (void)enableTap { gEnabled = !gEnabled; savePrefs(); if (!gEnabled) clearArrow(); [self populate]; }
- (void)debugTap {
    [self animateOut];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showDebugLog(); });
}
- (void)creditsTap {
    [self animateOut];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showCredits(); });
}
- (void)closeTap { [self animateOut]; }

- (void)animateIn {
    [self layoutIfNeeded];
    CGFloat h = _card.frame.size.height > 0 ? _card.frame.size.height : 420;
    _card.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:^{
        _card.transform = CGAffineTransformIdentity;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    } completion:nil];
}
- (void)animateOut {
    CGFloat h = _card.frame.size.height > 0 ? _card.frame.size.height : 420;
    [UIView animateWithDuration:0.26 animations:^{
        _card.transform = CGAffineTransformMakeTranslation(0, h);
        self.backgroundColor = [UIColor clearColor];
    } completion:^(BOOL f) {
        [self removeFromSuperview];
        gMenuWin.hidden = YES;
        [[UIApplication sharedApplication].delegate.window makeKeyWindow];
    }];
}
@end

static void showSettingsMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [CHSettingsPanel show]; });
}

static void updateFloatBtn(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFloatBtn) return;
        [gFloatBtn setTitle:text forState:UIControlStateNormal];

        CGFloat w = (text.length > 2) ? 56 : 40;
        CGFloat h = 32;
        CGRect f = gFloatBtn.frame;
        gFloatBtn.frame = CGRectMake(f.origin.x, f.origin.y, w, h);
        gFloatBtn.titleLabel.font = (text.length > 2)
            ? [UIFont boldSystemFontOfSize:13]
            : [UIFont systemFontOfSize:20];
    });
}

static void showQualityToast(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFloatBtn || !gBtnWin) return;
        UILabel *toast = [[UILabel alloc] init];
        toast.text = text;
        toast.font = [UIFont boldSystemFontOfSize:13];
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [(color ?: [UIColor darkGrayColor]) colorWithAlphaComponent:0.92];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 9;
        toast.clipsToBounds = YES;
        [toast sizeToFit];
        CGFloat w = toast.bounds.size.width + 20, h = 24;
        CGPoint c = gFloatBtn.center;
        toast.frame = CGRectMake(c.x - w / 2, c.y - 40, w, h);
        toast.alpha = 0;
        [gBtnWin addSubview:toast];
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; }];
        [UIView animateWithDuration:0.3 delay:1.6 options:0
            animations:^{ toast.alpha = 0; }
            completion:^(BOOL fin) { [toast removeFromSuperview]; }];
    });
}

static BOOL isBoardOnScreen(UIView *v) {
    if (!v) return NO;
    UIWindow *w = v.window;
    if (!w) return NO;
    if (v.hidden || v.alpha < 0.05) return NO;
    UIView *a = v.superview;
    for (int g = 0; a && g < 40; g++) {
        if (a.hidden || a.alpha < 0.05) return NO;
        a = a.superview;
    }
    CGRect inWin = [v convertRect:v.bounds toView:nil];
    CGRect inter = CGRectIntersection(inWin, w.bounds);
    if (CGRectIsNull(inter)) return NO;
    CGFloat ownArea = v.bounds.size.width * v.bounds.size.height;
    if (ownArea <= 1) return NO;
    CGFloat visArea = inter.size.width * inter.size.height;
    return (visArea / ownArea) > 0.5;
}

#pragma mark - Eval Bar (horizontal, above board)

static NSMutableArray *gEvalBarLayers = nil;

static void removeEvalBar(void) {
    for (CALayer *l in gEvalBarLayers) [l removeFromSuperlayer];
    [gEvalBarLayers removeAllObjects];
}

static void updateEvalBar(void) {
    removeEvalBar();
    UIView *board = gDrawBoard ?: gBoardView ?: gBotBoard;
    if (!gShowEvalBar || !gBarHave || !board || !board.window || !isBoardOnScreen(board)) return;

    CGFloat barH = 16;
    CGRect bF = board.bounds;
    if (bF.size.width < 60) return;
    BOOL masked = board.layer.masksToBounds;

    // horizontal bar sitting above the board, raised by an extra bar-height so
    // it never touches the top rank; falls back to an overlay pinned inside
    // the top edge if the board clips its own layer
    CGRect bar = CGRectMake(2, masked ? 3 : -(barH * 2 + 6), bF.size.width - 4, barH);

    double frac = 0.5;
    NSString *txt;
    if (gBarIsMate) {
        BOOL whiteMates = gBarMateWhite > 0;
        frac = whiteMates ? 0.95 : 0.05;
        txt = [NSString stringWithFormat:@"%@M%d", whiteMates ? @"" : @"-", abs(gBarMateWhite)];
    } else {
        double wp = evalToWinPct(gBarWhiteEval, NO, 0);
        frac = MIN(0.97, MAX(0.03, wp / 100.0));
        txt = [NSString stringWithFormat:@"%+.1f", gBarWhiteEval];
    }
    UIColor *txtColor = frac >= 0.5 ? UIColor.blackColor : UIColor.whiteColor;

    if (!gEvalBarLayers) gEvalBarLayers = [NSMutableArray array];

    CALayer *bg = [CALayer layer];
    bg.frame = bar;
    bg.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.94].CGColor;
    bg.cornerRadius = 4;
    bg.zPosition = 10005;

    CALayer *fill = [CALayer layer];
    fill.frame = CGRectMake(1, 1, MAX(2, (bar.size.width - 2) * frac), barH - 2);
    fill.backgroundColor = [UIColor whiteColor].CGColor;
    fill.cornerRadius = 3;
    fill.zPosition = 10006;

    CATextLayer *tl = [CATextLayer layer];
    tl.frame = bar;
    tl.string = txt;
    tl.fontSize = 11;
    tl.alignmentMode = kCAAlignmentCenter;
    tl.foregroundColor = txtColor.CGColor;
    tl.contentsScale = [UIScreen mainScreen].scale;
    tl.zPosition = 10007;

    [board.layer addSublayer:bg];
    [board.layer addSublayer:fill];
    [board.layer addSublayer:tl];
    [gEvalBarLayers addObjectsFromArray:@[bg, fill, tl]];
}

static BOOL detectBoardFlipped(UIView *board) {
    if (gForcedFlip >= 0) return gForcedFlip ? YES : NO;
    @try {
        SEL flipSel = NSSelectorFromString(@"isFlipped");
        if ([board respondsToSelector:flipSel]) {
            typedef BOOL (*BoolGetter)(id, SEL);
            return ((BoolGetter)objc_msgSend)(board, flipSel) ? YES : NO;
        }
        Ivar ivar = class_getInstanceVariable([board class], "_flipped");
        if (!ivar) ivar = class_getInstanceVariable([board class], "isFlipped");
        if (ivar) {
            ptrdiff_t offset = ivar_getOffset(ivar);
            return *(BOOL *)((char *)(__bridge void *)board + offset) ? YES : NO;
        }
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"flip detect err: %@", e.reason]);
    }
    return NO;
}

#pragma mark - Auto Play (synthetic touches)

static void setMyColor(NSInteger c, NSString *src) {
    if (gMyColor != c) {
        dbg([NSString stringWithFormat:@"COLOR %ld -> %ld  (%@)", (long)gMyColor, (long)c, src]);
    }
    gMyColor = c;
}

static int fenSideToMove(NSString *fen) {
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 2) return -1;
    NSString *f = [parts[1] lowercaseString];
    if ([f isEqualToString:@"b"]) return 1;
    if ([f isEqualToString:@"w"]) return 0;
    return -1;
}


static NSMutableArray *gFakeTouches = nil;

static NSMutableSet *sDumpedClasses = nil;

static void dumpMoveSelectors(id obj, NSString *tag) {
    if (!obj) return;
    Class c = object_getClass(obj);
    if (!c) return;
    if (!sDumpedClasses) sDumpedClasses = [NSMutableSet set];
    NSString *key = [tag stringByAppendingString:NSStringFromClass(c)];
    if ([sDumpedClasses containsObject:key]) return;
    [sDumpedClasses addObject:key];

    NSArray *keywords = @[@"move", @"play", @"tap", @"touch", @"piece",
                          @"select", @"square", @"drag", @"click", @"perform"];
    unsigned int n = 0;
    Method *methods = class_copyMethodList(c, &n);
    if (methods) {
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n && hits.count < 50; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            for (NSString *k in keywords) {
                if ([lower containsString:k]) { [hits addObject:name]; break; }
            }
        }
        free(methods);
        if (hits.count)
            dbg([NSString stringWithFormat:@"DUMP[%@] %@ (%lu): %@", tag, NSStringFromClass(c),
                 (unsigned long)hits.count, [hits componentsJoinedByString:@", "]]);
    }

    Class meta = object_getClass(c);
    unsigned int cn = 0;
    Method *cmethods = class_copyMethodList(meta, &cn);
    if (cmethods) {
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < cn && hits.count < 30; i++) {
            NSString *name = NSStringFromSelector(method_getName(cmethods[i]));
            NSString *lower = name.lowercaseString;
            for (NSString *k in keywords) {
                if ([lower containsString:k]) { [hits addObject:name]; break; }
            }
        }
        free(cmethods);
        if (hits.count)
            dbg([NSString stringWithFormat:@"DUMP[%@] +(%@): %@", tag,
                 NSStringFromClass(c), [hits componentsJoinedByString:@", "]]);
    }
}

static UITouch *chAcquireFakeTouch(void) {
    if (!gFakeTouches) gFakeTouches = [NSMutableArray array];
    UITouch *t = gFakeTouches.firstObject;
    if (!t) {
        t = [[UITouch alloc] init];
        [gFakeTouches addObject:t];
    }
    return t;
}

static void chSetKvc(id obj, NSString *key, id val) {
    @try {
        [obj setValue:val forKey:key];
    } @catch (NSException *e) {
        static NSMutableSet *sWarnedKeys = nil;
        if (!sWarnedKeys) sWarnedKeys = [NSMutableSet set];
        if (![sWarnedKeys containsObject:key]) {
            [sWarnedKeys addObject:key];
            dbg([NSString stringWithFormat:@"autoplay: UITouch key '%@' unsupported, skipped", key]);
        }
    }
}

static void chFakeTouchFire(CGPoint ptInWin, UIWindow *win, UITouchPhase phase) {
    @try {
        UITouch *touch = chAcquireFakeTouch();
        chSetKvc(touch, @"_phase", @(phase));
        chSetKvc(touch, @"_locationInWindow", [NSValue valueWithCGPoint:ptInWin]);
        chSetKvc(touch, @"_tapCount", @1);
        chSetKvc(touch, @"_timestamp", @(NSDate.date.timeIntervalSince1970));
        chSetKvc(touch, @"_window", win);

        UIView *target = [win hitTest:ptInWin withEvent:nil] ?: win;
        chSetKvc(touch, @"_view", target);

        static UIEvent *sCarrierEvent = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sCarrierEvent = [[UIEvent alloc] init]; });

        NSSet *touches = [NSSet setWithObject:touch];
        switch (phase) {
            case UITouchPhaseBegan:
                [target touchesBegan:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseMoved:
                [target touchesMoved:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseCancelled:
                [target touchesCancelled:touches withEvent:sCarrierEvent];
                break;
            default:
                [target touchesEnded:touches withEvent:sCarrierEvent];
                break;
        }
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"autoplay touch err: %@", e.reason]);
    }
}

static BOOL playMoveOnBoard(NSString *uci, NSString *fenSnap, UIView *preferredBoard) {
    if (!gEnabled || !gAutoPlay) return NO;
    if (![fenSnap isEqualToString:gLastFen]) return NO;

    UIView *board = preferredBoard;
    if (!board || !board.window || !isBoardOnScreen(board)) {
        board = gDrawBoard ?: gBoardView ?: gBotBoard;
    }
    if (!board || !board.window || !isBoardOnScreen(board)) { dbg(@"autoplay: no board"); return NO; }

    int fromSq = 0, toSq = 0;
    if (!parseMoveUCI(uci, &fromSq, &toSq)) { dbg(@"autoplay: bad move"); return NO; }

    BOOL flipped = detectBoardFlipped(board);
    CGRect winRect = [board convertRect:board.bounds toView:nil];
    UIWindow *win = board.window;

    CGPoint fromLocal = squareToPoint(fromSq, board.bounds, flipped);
    CGPoint toLocal   = squareToPoint(toSq,   board.bounds, flipped);
    CGPoint fromWin = CGPointMake(winRect.origin.x + fromLocal.x, winRect.origin.y + fromLocal.y);
    CGPoint toWin   = CGPointMake(winRect.origin.x + toLocal.x,   winRect.origin.y + toLocal.y);

    BOOL promo = uci.length > 4;
    CGPoint promoWin = CGPointZero;
    if (promo) {
        int mover = fenSideToMove(fenSnap);
        if (mover < 0) mover = gSide;
        int qSq = (mover == 1) ? toSq + 8 : toSq - 8;
        if (qSq < 0 || qSq > 63) qSq = toSq;
        CGPoint qLocal = squareToPoint(qSq, board.bounds, flipped);
        promoWin = CGPointMake(winRect.origin.x + qLocal.x, winRect.origin.y + qLocal.y);
    }

    dbg([NSString stringWithFormat:@"autoplay: %@", uci]);
    showQualityToast(@"▶ Auto Play", CH_ACCENT);

    chFakeTouchFire(fromWin, win, UITouchPhaseBegan);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        chFakeTouchFire(fromWin, win, UITouchPhaseEnded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            chFakeTouchFire(toWin, win, UITouchPhaseBegan);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                chFakeTouchFire(toWin, win, UITouchPhaseEnded);
                if (promo) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        chFakeTouchFire(promoWin, win, UITouchPhaseBegan);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            chFakeTouchFire(promoWin, win, UITouchPhaseEnded);
                        });
                    });
                }
            });
        });
    });
    return YES;
}

static void tryAutoPlay(NSString *bestmove, NSString *altMove, NSString *fenSnap, UIView *preferredBoard) {
    if (!gAutoPlay || !gEnabled) return;
    if (gPuzzleCtx) return;
    if (bestmove.length < 4) return;
    if (!fenSnap.length || [fenSnap isEqualToString:gLastAutoPlayed]) return;

    if (gMyColor < 0) { dbg(@"autoplay: color unknown, skip"); return; }
    int snapSide = fenSideToMove(fenSnap);
    if (snapSide < 0 || snapSide != gMyColor) { dbg(@"autoplay: not our turn, skip"); return; }

    NSString *chosen = bestmove;
    if (gAutoPlaySecondBest && altMove.length >= 4 && ![altMove isEqualToString:bestmove]) {
        uint32_t chance = (uint32_t)MAX(0, MIN(100, (int)gAutoPlaySecondBestPct));
        if (chance > 0 && arc4random_uniform(100) < chance) chosen = altMove;
    }

    double delay = gAutoPlayDelay;
    if (gAutoPlayJitterEnabled && gAutoPlayJitterRange > 0.0) {
        double r = gAutoPlayJitterRange;
        double jit = ((double)arc4random_uniform(2001) / 1000.0 - 1.0) * r;
        delay += jit;
    }
    if (delay < 0.0) delay = 0.0;
    if (delay > 6.0) delay = 6.0;

    __block int retries = 0;
    __block void (^attempt)(void) = nil;
    __weak void (^weakAttempt)(void) = nil;
    attempt = ^{
        if (!gAutoPlay || !gEnabled) return;
        if (![fenSnap isEqualToString:gLastFen]) return;
        if ([fenSnap isEqualToString:gLastAutoPlayed]) return;
        if (gMyColor < 0 || snapSide != gMyColor) return;
        if (playMoveOnBoard(chosen, fenSnap, preferredBoard)) {
            gLastAutoPlayed = [fenSnap copy];
            return;
        }
        retries++;
        if (retries < 15) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), weakAttempt);
        }
    };
    weakAttempt = attempt;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), weakAttempt);
}

static void applyEngineResult(NSString *bestmove, NSArray *extraMoves, BOOL isMate, int mateIn,
                              double rawEval, UIView *drawBoard) {

    double evalForUs = rawEval;
    if (gMyColor == 1) evalForUs = -rawEval;
    if (isMate && gMyColor == 1) mateIn = -mateIn;

    gLastEval = isMate ? (mateIn > 0 ? 999 : -999) : evalForUs;
    gHasEval = YES;

    // eval bar data (white perspective)
    gBarWhiteEval = rawEval;
    gBarIsMate = isMate;
    gBarMateWhite = isMate ? ((gMyColor == 1) ? -mateIn : mateIn) : 0;
    gBarHave = YES;

    NSString *evalStr = @"";
    NSString *btnText = @"♟";
    if (isMate) {
        evalStr = [NSString stringWithFormat:@" M%d", abs(mateIn)];
        btnText = [NSString stringWithFormat:@"M%d", abs(mateIn)];
    } else if (gShowWinPct) {
        double wp = evalToWinPct(evalForUs, NO, 0);
        evalStr = [NSString stringWithFormat:@" %.0f%%", wp];
        btnText = [NSString stringWithFormat:@"%.0f%%", wp];
    } else {
        evalStr = [NSString stringWithFormat:@" %+.1f", evalForUs];
        btnText = [NSString stringWithFormat:@"%+.1f", evalForUs];
    }

    dbg([NSString stringWithFormat:@"suggest: %@%@", bestmove, evalStr]);
    updateFloatBtn(btnText);

    UIView *board = drawBoard;
    NSString *altMove = nil;
    if (extraMoves.count > 0) {
        NSDictionary *c = extraMoves.firstObject;
        if ([c isKindOfClass:[NSDictionary class]]) altMove = c[@"move"];
    }
    if (!board || !board.window) board = gDrawBoard ?: gBoardView;
    if (board) {
        BOOL flipped = detectBoardFlipped(board);
        double arrowEval = isMate ? (mateIn > 0 ? 99 : -99) : evalForUs;
        NSMutableArray *arrows = [NSMutableArray array];
        [arrows addObject:@{@"move": bestmove, @"eval": @(arrowEval), @"rank": @0,
                            @"label": formatEvalLabel(evalForUs, isMate, mateIn)}];
        int rank = 1;
        for (NSDictionary *c in extraMoves) {
            if (rank >= gArrowCount) break;
            [arrows addObject:@{@"move": c[@"move"], @"eval": @(arrowEval), @"rank": @(rank),
                                @"label": c[@"label"] ?: @""}];
            rank++;
        }
        drawArrowsOnBoard(arrows, board, flipped);
        updateEvalBar();
    } else {
        dbg(@"no board ref for arrow");
    }
    tryAutoPlay(bestmove, altMove, gLastFen, board);
}

static BOOL fenHasBothKings(NSString *fen) {
    NSString *place = [[fen componentsSeparatedByString:@" "] firstObject];
    int K = 0, k = 0;
    for (NSUInteger i = 0; i < place.length; i++) {
        unichar c = [place characterAtIndex:i];
        if (c == 'K') K++; else if (c == 'k') k++;
    }
    return K == 1 && k == 1;
}

static NSArray<NSString *> *maiaCandidatePaths(void) {
    NSMutableArray *c = [@[
        @"/var/jb/Library/Application Support/Chess/maia3_5m.mlpackage",
        @"/Library/Application Support/Chess/maia3_5m.mlpackage",
    ] mutableCopy];
    NSString *res = [[NSBundle mainBundle] resourcePath];
    if (res) {
        [c addObject:[res stringByAppendingPathComponent:@"maia3_5m.mlpackage"]];
        [c addObject:[res stringByAppendingPathComponent:@"Chess/maia3_5m.mlpackage"]];
    }
    // resolve the real jailbreak root via /private/preboot if /var/jb is unreadable from the app sandbox
    @try {
        NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/private/preboot" error:nil];
        for (NSString *uuid in uuids) {
            NSString *base = [@"/private/preboot/" stringByAppendingString:uuid];
            NSArray *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
            for (NSString *s in subs) {
                if (![s hasPrefix:@"jb-"]) continue;
                [c addObject:[[base stringByAppendingPathComponent:s]
                    stringByAppendingPathComponent:@"Library/Application Support/Chess/maia3_5m.mlpackage"]];
            }
        }
    } @catch (NSException *e) {}
    return c;
}

static BOOL sMaiaRetryDone = NO;

static BOOL isInitialStartFEN(NSString *fen) {
    if (!fen.length) return NO;
    return [fen hasPrefix:@"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w "];
}

static void ensureMaiaLoaded(void) {
    if (MaiaAvailable()) return;
    if (sMaiaRetryDone) return;
    sMaiaRetryDone = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *c in maiaCandidatePaths()) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:c]) {
                BOOL ok = MaiaLoad([c UTF8String]);
                dbg([NSString stringWithFormat:@"maia retry load %@: %@", ok ? @"OK" : @"FAIL", c]);
                if (ok) return;
            }
        }
        // filesystem lookup failed (sandboxed app can't see /var/jb) — use the model embedded in our dylib
        BOOL ok = MaiaLoadEmbedded();
        dbg([NSString stringWithFormat:@"maia embedded load: %@", ok ? @"OK" : @"FAIL"]);
    });
}

// SAN for one UCI move in the given position: board state gives piece/capture,
// Stockfish legal-move enumeration handles disambiguation.
static NSString *sanForMove(NSString *fen, NSString *uci) {
    parseFEN(fen);
    int from = 0, to = 0;
    if (!parseMoveUCI(uci, &from, &to)) return nil;
    if (from < 0 || from > 63 || to < 0 || to > 63) return nil;
    char piece = gBoard[from];
    if (piece == ' ') return nil;
    char up = (char)toupper((unsigned char)piece);

    if (up == 'K' && abs((to % 8) - (from % 8)) == 2)
        return (to % 8 == 6) ? @"O-O" : @"O-O-O";

    BOOL isPawn = (up == 'P');
    BOOL capture = (gBoard[to] != ' ');
    if (!capture && isPawn && to == gEp) capture = YES;

    NSMutableString *san = [NSMutableString string];
    if (!isPawn) [san appendFormat:@"%c", up];
    else if (capture) [san appendFormat:@"%c", 'a' + (from % 8)];

    if (!isPawn && up != 'K') {
        char buf[256 * 6];
        int n = StockfishLegalMoves([fen UTF8String], buf, 256);
        BOOL anyOther = NO, sameFile = NO, sameRank = NO;
        for (int i = 0; i < n; i++) {
            NSString *m = [NSString stringWithFormat:@"%s", buf + i * 6];
            int f2 = 0, t2 = 0;
            if (!parseMoveUCI(m, &f2, &t2)) continue;
            if (f2 == from || t2 != to) continue;
            if (gBoard[f2] != piece) continue;
            anyOther = YES;
            if ((f2 % 8) == (from % 8)) sameFile = YES;
            if ((f2 / 8) == (from / 8)) sameRank = YES;
        }
        if (anyOther) {
            if (!sameFile)      [san appendFormat:@"%c", 'a' + (from % 8)];
            else if (!sameRank) [san appendFormat:@"%c", '1' + (from / 8)];
            else                [san appendFormat:@"%c%c", 'a' + (from % 8), '1' + (from / 8)];
        }
    }

    if (capture) [san appendString:@"x"];
    [san appendFormat:@"%c%c", 'a' + (to % 8), '1' + (to / 8)];
    char promo = (uci.length > 4) ? (char)toupper([uci characterAtIndex:4]) : 0;
    if (promo) [san appendFormat:@"=%c", promo];
    return san;
}

static NSString *buildPGN(void) {
    if (!gUciSeq.length || !gPgnStartFen.length) return nil;

    NSArray *tokens = [gUciSeq componentsSeparatedByString:@" "];
    NSMutableArray *sans = [NSMutableArray array];

    parseFEN(gPgnStartFen);
    NSInteger moveNo = gFull;
    BOOL blackFirst = (gSide == 1);

    for (NSString *tok in tokens) {
        if (tok.length < 4) continue;
        NSString *fen = generateFEN();
        NSString *san = sanForMove(fen, tok);
        if (!san.length) return nil;
        [sans addObject:san];
        int from = 0, to = 0;
        parseMoveUCI(tok, &from, &to);
        char promo = (tok.length > 4) ? (char)tolower([tok characterAtIndex:4]) : 0;
        applyMove(from, to, promo);
    }
    if (!sans.count) return nil;

    NSMutableString *body = [NSMutableString string];
    NSInteger n = moveNo;
    if (!blackFirst) {
        for (NSUInteger i = 0; i < sans.count; i += 2) {
            [body appendFormat:@"%@%@. %@", body.length ? @" " : @"", @(n++), sans[i]];
            if (i + 1 < sans.count) [body appendFormat:@" %@", sans[i + 1]];
        }
    } else {
        [body appendFormat:@"%ld... %@", (long)n, sans[0]];
        for (NSUInteger i = 1; i < sans.count; i += 2) {
            [body appendFormat:@" %ld. %@", ++n, sans[i]];
            if (i + 1 < sans.count) [body appendFormat:@" %@", sans[i + 1]];
        }
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy.MM.dd";

    NSMutableString *pgn = [NSMutableString string];
    [pgn appendFormat:
        @"[Event \"Chess Assistant\"]\n"
         "[Site \"?\"]\n"
         "[Date \"%@\"]\n"
         "[Round \"?\"]\n"
         "[White \"?\"]\n"
         "[Black \"?\"]\n"
         "[Result \"*\"]\n",
        [df stringFromDate:[NSDate date]]];    NSString *startpos = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (![gPgnStartFen isEqualToString:startpos]) {
        [pgn appendFormat:@"[SetUp \"1\"]\n[FEN \"%@\"]\n", gPgnStartFen];
    }
    [pgn appendFormat:@"\n%@\n*\n", body];
    return pgn;
}

static int humanizedPickIndex(const EngineLine *lines, int count, int elo) {
    if (count < 2 || elo >= 2000) return 0;
    if (!lines[0].hasScore || lines[0].isMate) return 0;

    double T = (2000.0 - (double)elo) / 6.0;
    if (T < 1.0) return 0;
    double maxLoss = 60.0 + (2000.0 - (double)elo) * 0.60;
    if (maxLoss > 900.0) maxLoss = 900.0;

    int n = count > 8 ? 8 : count;
    double w[8]; double sum = 0;
    for (int i = 0; i < n; i++) {
        w[i] = 0;
        if (!lines[i].hasScore || lines[i].isMate) continue;
        double loss = (double)(lines[0].score - lines[i].score);
        if (loss < 0) loss = 0;
        if (loss > maxLoss) continue;
        w[i] = exp(-loss / T);
        sum += w[i];
    }
    if (sum <= 0) return 0;
    double r = ((double)arc4random_uniform(1000000) / 1000000.0) * sum;
    double acc = 0;
    for (int i = 0; i < n; i++) { acc += w[i]; if (w[i] > 0 && r <= acc) return i; }
    return 0;
}

static void fetchMove(NSString *fen) {
    if (!gEnabled || !fen.length) return;
    if (!fenHasBothKings(fen)) return;
    if (!StockfishFenLegal([fen UTF8String])) { dbg(@"skip illegal pos"); return; }
    if (isInitialStartFEN(fen)) gLastAutoPlayed = nil;
    if ([fen isEqualToString:gLastFen]) return;

    if (gFetching && gLastFetch && [[NSDate date] timeIntervalSinceDate:gLastFetch] > 5.0) {
        gFetching = NO;
    }
    if (gFetching) { gPendingFen = [fen copy]; return; }

    gLastFen = [fen copy];
    gFetching = YES;
    gLastFetch = [NSDate date];
    NSString *snap = [fen copy];

    __block UIView *drawBoard = gDrawBoard ?: gBoardView;

    BOOL stmWhite = ([fen rangeOfString:@" w "].location != NSNotFound);

    if (gUseMaia) ensureMaiaLoaded();
    if (gUseMaia && MaiaAvailable()) {
        dbg([NSString stringWithFormat:@"maia elo%ld: %@", (long)gElo,
             [fen substringToIndex:MIN(fen.length, 45)]]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MaiaGo([fen UTF8String], (int)gElo, (int)gElo, ^(MaiaResult r) {
                NSString *bm = r.ok ? [NSString stringWithUTF8String:r.move] : nil;
                double rawWhite = r.whiteEval;
                NSMutableArray *extras = [NSMutableArray array];
                for (int i = 1; i < r.count && i < gArrowCount; i++) {
                    [extras addObject:@{@"move": [NSString stringWithUTF8String:r.moves[i]],
                                        @"label": [NSString stringWithFormat:@"%.0f%%", r.policy[i] * 100.0]}];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    gFetching = NO;
                    if (gPendingFen && ![gPendingFen isEqualToString:gLastFen]) {
                        NSString *next = [gPendingFen copy];
                        gPendingFen = nil;
                        dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(next); });
                    } else {
                        gPendingFen = nil;
                    }
                    if (![snap isEqualToString:gLastFen]) { dbg(@"stale resp"); return; }
                    if (!bm.length) { dbg(@"maia no move"); return; }
                    applyEngineResult(bm, extras, NO, 0, rawWhite, drawBoard);
                });
            });
        });

        if (gTrackQuality) {
            NSInteger gdepth = MAX(14, eloToDepth(gElo));
            EngineGo([fen UTF8String], (int)gdepth, (int)gElo, 2,
                     ^(const EngineLine *lines, int count) {
                BOOL hasScore = (count > 0) ? lines[0].hasScore : NO;
                BOOL lmate = (count > 0) ? lines[0].isMate : NO;
                int  lscore = (count > 0) ? lines[0].score : 0;
                double secondWhite = 0; BOOL have2nd = NO;
                if (count >= 2 && lines[1].hasScore && !lines[1].isMate) {
                    double cp = lines[1].score / 100.0;
                    secondWhite = stmWhite ? cp : -cp;
                    have2nd = YES;
                }
                double rawWhite = 0; BOOL mate = NO;
                if (hasScore) {
                    if (lmate) mate = YES;
                    else { double cp = lscore / 100.0; rawWhite = stmWhite ? cp : -cp; }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    noteUserEval(snap, mate ? 0 : rawWhite, !mate && hasScore, secondWhite, have2nd);
                });
            });
        }
        return;
    }

    NSInteger depth = eloToDepth(gElo);
    dbg([NSString stringWithFormat:@"fetch d%ld: %@", (long)depth,
         [fen substringToIndex:MIN(fen.length, 45)]]);

    int multipv = gTrackQuality ? MAX((int)gArrowCount, 2) : (int)gArrowCount;
    if (gElo < 1600) multipv = MAX(multipv, 8);
    else if (gElo < 2000) multipv = MAX(multipv, 4);
    EngineGo([fen UTF8String], (int)depth, (int)gElo, multipv,
             ^(const EngineLine *lines, int count) {

        int pick = (count > 0) ? humanizedPickIndex(lines, count, (int)gElo) : 0;
        if (pick > 0) dbg([NSString stringWithFormat:@"humanized: played #%d of %d", pick + 1, count]);
        NSString *bm = (count > 0) ? [NSString stringWithUTF8String:lines[pick].move] : nil;
        BOOL hasScore = (count > 0) ? lines[0].hasScore : NO;
        BOOL lmate = (count > 0) ? lines[0].isMate : NO;
        int  lscore = (count > 0) ? lines[0].score : 0;

        int myColor = gMyColor;
        NSMutableArray *extras = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            if (i == pick) continue;
            NSString *mv = [NSString stringWithUTF8String:lines[i].move];
            double evWhite = 0; BOOL cm = NO; int cMate = 0;
            if (lines[i].hasScore) {
                if (lines[i].isMate) { cm = YES; cMate = stmWhite ? lines[i].score : -lines[i].score; }
                else { double cp = lines[i].score / 100.0; evWhite = stmWhite ? cp : -cp; }
            }
            double evUs = (myColor == 1) ? -evWhite : evWhite;
            int mateUs  = (myColor == 1) ? -cMate : cMate;
            [extras addObject:@{@"move": mv, @"label": formatEvalLabel(evUs, cm, mateUs)}];
        }

        double secondWhite = 0; BOOL have2nd = NO;
        if (count >= 2 && lines[1].hasScore && !lines[1].isMate) {
            double cp = lines[1].score / 100.0;
            secondWhite = stmWhite ? cp : -cp;
            have2nd = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            gFetching = NO;
            if (gPendingFen && ![gPendingFen isEqualToString:gLastFen]) {
                NSString *next = [gPendingFen copy];
                gPendingFen = nil;
                dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(next); });
            } else {
                gPendingFen = nil;
            }
            if (![snap isEqualToString:gLastFen]) { dbg(@"stale resp"); return; }
            if (!bm.length || [bm isEqualToString:@"(none)"]) {
                dbg(@"no bestmove"); return;
            }

            double rawWhite = 0; int mateIn = 0; BOOL mate = NO;
            if (hasScore) {
                if (lmate) { mate = YES; mateIn = stmWhite ? lscore : -lscore; }
                else { double cp = lscore / 100.0; rawWhite = stmWhite ? cp : -cp; }
            }
            applyEngineResult(bm, extras, mate, mateIn, rawWhite, drawBoard);
            if (gTrackQuality) noteUserEval(snap, mate ? 0 : rawWhite, !mate && hasScore, secondWhite, have2nd);
        });
    });
}

static __weak id gEngineCtrl = nil;
static __weak id gHookedEngine = nil;
static NSString *gLastEngineFEN = nil;

typedef struct { uint64_t w0; uint64_t w1; } RawSwiftString;

typedef RawSwiftString (*SwiftGetFenFunc)(void *self);
static SwiftGetFenFunc gOrigSwiftGetFen = NULL;

typedef NSString *(*SwiftStringBridgeFunc)(uint64_t w0, uint64_t w1);
static SwiftStringBridgeFunc gSwiftStringBridge = NULL;

static NSString *gSwiftFEN = nil;
static BOOL gSwiftHookActive = NO;

static RawSwiftString hook_swiftGetFen(void *self) {
    RawSwiftString result = gOrigSwiftGetFen(self);
    if (gSwiftStringBridge && gEnabled) {
        @autoreleasepool {
            @try {
                NSString *ns = gSwiftStringBridge(result.w0, result.w1);
                if ([ns isKindOfClass:[NSString class]] && ns.length > 10
                    && [ns containsString:@"/"]) {
                    gSwiftFEN = [ns copy];
                }
            } @catch (NSException *e) {}
        }
    }
    return result;
}

typedef RawSwiftString (*SwiftGetTcnFunc)(void *self);
static SwiftGetTcnFunc gOrigSwiftGetTcn = NULL;
static NSString *gSwiftTCN = nil;

static RawSwiftString hook_swiftGetTcn(void *self) {
    RawSwiftString result = gOrigSwiftGetTcn(self);
    if (gSwiftStringBridge && gEnabled) {
        @autoreleasepool {
            @try {
                NSString *ns = gSwiftStringBridge(result.w0, result.w1);
                if ([ns isKindOfClass:[NSString class]] && ns.length > 0) {
                    gSwiftTCN = [ns copy];
                }
            } @catch (NSException *e) {}
        }
    }
    return result;
}

static id searchVCForEngine(UIViewController *vc, int depth) {
    if (!vc || depth > 10) return nil;
    typedef id (*IdGetter)(id, SEL);
    IdGetter getObj = (IdGetter)objc_msgSend;
    SEL fenSel = NSSelectorFromString(@"getCurrentFen");

    NSArray *props = @[@"gameController", @"chessGameController", @"engineController",
                       @"interactor", @"viewModel", @"presenter", @"boardOwner",
                       @"game", @"chessGame", @"activeGame", @"currentGame",
                       @"delegate", @"coordinator"];
    for (NSString *prop in props) {
        SEL sel = NSSelectorFromString(prop);
        if (![vc respondsToSelector:sel]) continue;
        @try {
            id val = getObj(vc, sel);
            if (!val) continue;
            if ([val respondsToSelector:fenSel]) return val;

            for (NSString *sub in props) {
                SEL subSel = NSSelectorFromString(sub);
                if ([val respondsToSelector:subSel]) {
                    @try {
                        id sv = getObj(val, subSel);
                        if (sv && [sv respondsToSelector:fenSel]) return sv;
                    } @catch (NSException *e) {}
                }
            }
        } @catch (NSException *e) {}
    }

    for (UIViewController *child in vc.childViewControllers) {
        id found = searchVCForEngine(child, depth + 1);
        if (found) return found;
    }
    if (vc.presentedViewController) {
        id found = searchVCForEngine(vc.presentedViewController, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView *findBoardArea(UIView *view, int depth) {
    if (!view || depth > 25) return nil;
    CGFloat w = view.bounds.size.width, h = view.bounds.size.height;

    if (w > 200 && h > 200 && fabs(w - h) < w * 0.15
        && !view.hidden && view.alpha > 0.1
        && h < [UIScreen mainScreen].bounds.size.height * 0.8) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = findBoardArea(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL processBotBoard(UIView *board);

static id findOnlineGame(UIView *board) {
    if (!board) return nil;
    SEL encSel = NSSelectorFromString(@"encodedMoves");
    NSArray *sels = @[@"game", @"chessGame", @"currentGame", @"gameModel",
                      @"boardModel", @"chessBoardModel", @"viewModel", @"activeGame"];
    UIResponder *r = board;
    for (int d = 0; d < 16 && r; d++) {
        for (NSString *s in sels) {
            SEL sel = NSSelectorFromString(s);
            if ([r respondsToSelector:sel]) {
                @try {
                    id g = ((id (*)(id, SEL))objc_msgSend)(r, sel);
                    if (g && [g respondsToSelector:encSel]) return g;
                } @catch (NSException *e) {}
            }
        }
        r = [r nextResponder];
    }
    return nil;
}

static BOOL drivePuzzle(UIView *board);

static void enginePollTick(void) {
    if (!gEnabled) return;

    if (gHasEval &&
        !(gBotBoard  && isBoardOnScreen(gBotBoard)) &&
        !(gDrawBoard && isBoardOnScreen(gDrawBoard))) {
        clearArrow();
        removeEvalBar();
        updateFloatBtn(@"♟");
        gHasEval = NO;
        gBarHave = NO;
        gLastFen = nil;
        resetAccuracy();
    }

    if (gPuzzleBoard && isBoardOnScreen(gPuzzleBoard)) {
        if (drivePuzzle(gPuzzleBoard)) return;
    }

    BOOL botMoreRecent = gBotSeen && (!gOnlineSeen ||
        [gBotSeen compare:gOnlineSeen] == NSOrderedDescending);

    if (botMoreRecent) {
        if (processBotBoard(gBotBoard)) return;

    }

    if (!gOnlineGame) gOnlineGame = findOnlineGame(gBoardView);
    if (gOnlineGame) {
        if (gOnlineDrawBoard) gDrawBoard = gOnlineDrawBoard;
        reassertArrow(gDrawBoard);
        updateEvalBar();
        @try {
            typedef NSString *(*SG)(id, SEL);
            SEL encSel = NSSelectorFromString(@"encodedMoves");
            if ([gOnlineGame respondsToSelector:encSel]) {
                NSString *encoded = ((SG)objc_msgSend)(gOnlineGame, encSel);
                SEL iSel = NSSelectorFromString(@"initialFEN");
                NSString *iFen = [gOnlineGame respondsToSelector:iSel]
                                  ? ((SG)objc_msgSend)(gOnlineGame, iSel) : nil;
                if (!iFen.length) iFen = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
                NSString *fen = decodeTCNToFEN(iFen, encoded ?: @"");
                if (fen.length) {
                    parseFEN(fen);
                    if (!(gMyColor >= 0 && gMyColor != gSide)) {
                        gForcedFlip = -1;
                        fetchMove(fen);
                    } else {
                        clearArrow();
                        analyzeUserMove(fen);
                    }
                }
            }
        } @catch (NSException *e) {}
        return;
    }

    if (gSwiftHookActive) {
        NSString *sfn = gSwiftFEN;
        if (sfn.length > 10 && [sfn containsString:@"/"]) {
            if ([sfn isEqualToString:gLastEngineFEN]) return;
            gLastEngineFEN = [sfn copy];
            parseFEN(sfn);

            if (gMyColor >= 0 && gMyColor != gSide) { analyzeUserMove(sfn); return; }

            dbg([NSString stringWithFormat:@"SWIFT FEN: %@",
                 [sfn substringToIndex:MIN(sfn.length, 55)]]);

            if (!gBoardView || ![(UIView *)gBoardView window]) {
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    if (win == gBtnWin || win == gMenuWin) continue;
                    UIView *board = findBoardArea(win, 0);
                    if (board) { gBoardView = board; break; }
                }
            }
            fetchMove(sfn);
            return;
        }

        NSString *tcn = gSwiftTCN;
        if (tcn.length > 0) {
            NSString *startFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
            NSString *decoded = decodeTCNToFEN(startFEN, tcn);
            if (decoded.length > 10 && [decoded containsString:@"/"]) {
                if ([decoded isEqualToString:gLastEngineFEN]) return;
                gLastEngineFEN = [decoded copy];
                parseFEN(decoded);

                if (gMyColor >= 0 && gMyColor != gSide) { analyzeUserMove(decoded); return; }

                dbg([NSString stringWithFormat:@"SWIFT TCN→FEN: %@",
                     [decoded substringToIndex:MIN(decoded.length, 55)]]);

                if (!gBoardView || ![(UIView *)gBoardView window]) {
                    for (UIWindow *win in [UIApplication sharedApplication].windows) {
                        if (win == gBtnWin || win == gMenuWin) continue;
                        UIView *board = findBoardArea(win, 0);
                        if (board) { gBoardView = board; break; }
                    }
                }
                fetchMove(decoded);
                return;
            }
        }

        return;
    }

    if (!gEngineCtrl && gHookedEngine) {
        gEngineCtrl = gHookedEngine;
        dbg([NSString stringWithFormat:@"ENGINE: via hook %@",
             NSStringFromClass([gHookedEngine class])]);
        dumpMoveSelectors(gHookedEngine, @"engine");
    }

    if (!gEngineCtrl) {
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            UIViewController *root = win.rootViewController;
            if (!root) continue;
            id found = searchVCForEngine(root, 0);
            if (found) {
                gEngineCtrl = found;
                dbg([NSString stringWithFormat:@"ENGINE: found %@",
                     NSStringFromClass([found class])]);
                dumpMoveSelectors(found, @"engine");
                break;
            }
        }
        if (!gEngineCtrl) return;
    }

    NSArray *fenSelNames = @[@"getCurrentFen", @"getMainLineTcnString",
                              @"currentFen", @"fen", @"positionFen"];
    NSString *fen = nil;

    for (NSString *selName in fenSelNames) {
        SEL sel = NSSelectorFromString(selName);

        if ([gEngineCtrl respondsToSelector:sel]) {
            @try {
                typedef NSString *(*StrGetter)(id, SEL);
                NSString *result = ((StrGetter)objc_msgSend)(gEngineCtrl, sel);
                if ([result isKindOfClass:[NSString class]] && result.length > 10
                    && [result containsString:@"/"]) {
                    fen = result;
                    static NSString *sLoggedSel = nil;
                    if (![selName isEqualToString:sLoggedSel]) {
                        sLoggedSel = selName;
                        dbg([NSString stringWithFormat:@"ENGINE FEN via %@", selName]);
                    }
                    break;
                }
            } @catch (NSException *e) {}
        }
    }

    if (!fen) {
        @try {
            typedef NSString *(*StrGetter)(id, SEL);
            SEL fenSel = NSSelectorFromString(@"getCurrentFen");
            NSString *result = ((StrGetter)objc_msgSend)(gEngineCtrl, fenSel);
            if ([result isKindOfClass:[NSString class]] && result.length > 10
                && [result containsString:@"/"]) {
                fen = result;
                static BOOL sLoggedBrute = NO;
                if (!sLoggedBrute) { sLoggedBrute = YES; dbg(@"ENGINE FEN via brute getCurrentFen"); }
            }
        } @catch (NSException *e) {

            static BOOL sLoggedFail = NO;
            if (!sLoggedFail) {
                sLoggedFail = YES;
                dbg([NSString stringWithFormat:@"ENGINE no FEN method works: %@", e.reason]);
            }
            gEngineCtrl = nil;
            return;
        }
    }

    if (!fen) return;
    if ([fen isEqualToString:gLastEngineFEN]) return;
    gLastEngineFEN = [fen copy];
    parseFEN(fen);

    if (gMyColor >= 0 && gMyColor != gSide) return;

    dbg([NSString stringWithFormat:@"ENGINE FEN: %@",
         [fen substringToIndex:MIN(fen.length, 55)]]);

    if (!gBoardView || ![(UIView *)gBoardView window]) {
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            if (win == gBtnWin || win == gMenuWin) continue;
            UIView *board = findBoardArea(win, 0);
            if (board) { gBoardView = board; break; }
        }
    }

    gForcedFlip = -1;
    gDrawBoard = gBoardView;
    fetchMove(fen);
}

typedef void (*OrigLayout)(id, SEL);
static NSMutableDictionary *gOrigLayouts = nil;
static NSString *gLastEncoded = nil;
static NSDate   *gLastLayoutCheck = nil;

static NSMutableSet *gClassPtrSet = nil;
static void buildClassPtrSet(void) {
    gClassPtrSet = [NSMutableSet set];
    unsigned int n = 0;
    Class *cl = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++)
        [gClassPtrSet addObject:[NSValue valueWithPointer:(__bridge const void *)cl[i]]];
    if (cl) free(cl);
}
static NSString *safeClassName(const void *p) {
    if (!p) return nil;
    if (((uintptr_t)p & 0x7) != 0) return nil;
    if (malloc_size(p) == 0) return nil;
    Class c = object_getClass((__bridge id)p);
    if (!c) return nil;
    if (!gClassPtrSet) buildClassPtrSet();
    if (![gClassPtrSet containsObject:[NSValue valueWithPointer:(__bridge const void *)c]])
        return nil;
    return NSStringFromClass(c);
}

static NSString *gLastBotPlacement = nil;
static int       gBotSide = 0;
static char      gPrevBotBoard[8][8];
static BOOL      gHavePrevBoard = NO;

static NSString *buildBotFEN(UIView *board, int *outUserColor) {
    const uint8_t *base = (const uint8_t *)(__bridge const void *)board;

    Ivar dragIv = class_getInstanceVariable([board class], "pieceDragView");
    if (dragIv) {
        void *dp = *(void *const *)(base + ivar_getOffset(dragIv));
        if (safeClassName(dp) && ((__bridge UIView *)dp).subviews.count > 0) return nil;
    }

    Ivar povIv = class_getInstanceVariable([board class], "piecesOverlayView");
    ptrdiff_t povOff = povIv ? ivar_getOffset(povIv) : 408;
    void *povPtr = *(void *const *)(base + povOff);
    if (!safeClassName(povPtr)) return nil;
    UIView *overlay = (__bridge UIView *)povPtr;

    CGFloat sq = board.bounds.size.width / 8.0;
    if (sq <= 0) return nil;

    const char *LETTERS = "PNBRQK";

    NSArray<UIView *> *snapshot = [overlay.subviews copy];

    uint8_t pcColor[64], pcType[64]; int pcCol[64], pcRow[64], pcN = 0;
    for (UIView *pv in snapshot) {
        if (![NSStringFromClass([pv class]) containsString:@"PieceView"]) continue;

        const void *pvp = (__bridge const void *)pv;
        if (malloc_size(pvp) == 0) continue;
        if (pv.layer.animationKeys.count > 0) return nil;
        if (pv.hidden || pv.alpha < 0.5) return nil;

        const uint8_t *pb = (const uint8_t *)pvp;
        Ivar pieceIv = class_getInstanceVariable([pv class], "piece");
        ptrdiff_t pieceOff = pieceIv ? ivar_getOffset(pieceIv) : 512;
        uint8_t color = *(pb + pieceOff + 0);
        uint8_t type  = *(pb + pieceOff + 16);
        if (color < 1 || color > 2 || type < 1 || type > 6) continue;

        Ivar ghostIv = class_getInstanceVariable([pv class], "isGhost");
        if (ghostIv && *(pb + ivar_getOffset(ghostIv))) return nil;

        CGRect f = [pv convertRect:pv.bounds toView:board];
        CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
        int scol = (int)(cx / sq);
        int srow = (int)(cy / sq);
        if (scol < 0 || scol > 7 || srow < 0 || srow > 7) continue;
        if (fabs(cx - (scol * sq + sq / 2)) > sq * 0.35 ||
            fabs(cy - (srow * sq + sq / 2)) > sq * 0.35) return nil;

        if (pcN < 64) {
            pcColor[pcN] = color; pcType[pcN] = type;
            pcCol[pcN] = scol;    pcRow[pcN] = srow;   pcN++;
        }
    }
    if (pcN < 2) return nil;

    double wSum = 0, bSum = 0; int wN = 0, bN = 0;
    for (int i = 0; i < pcN; i++) {
        if (pcColor[i] == 1) { wSum += pcRow[i]; wN++; }
        else                 { bSum += pcRow[i]; bN++; }
    }
    double wAvg = wN ? wSum / wN : 0.0;
    double bAvg = bN ? bSum / bN : 7.0;
    BOOL flipped = (wAvg < bAvg);
    Ivar flipIv = class_getInstanceVariable([board class], "isFlipped");
    if (flipIv) {
        const uint8_t *bb = (const uint8_t *)(__bridge const void *)board;
        flipped = (*(bb + ivar_getOffset(flipIv)) & 1) ? YES : NO;
    }

    char bd[8][8];
    memset(bd, 0, sizeof(bd));
    for (int i = 0; i < pcN; i++) {
        int rankIdx, file;
        if (!flipped) { rankIdx = 7 - pcRow[i]; file = pcCol[i]; }
        else          { rankIdx = pcRow[i];     file = 7 - pcCol[i]; }
        if (rankIdx < 0 || rankIdx > 7 || file < 0 || file > 7) continue;
        char ch = LETTERS[pcType[i] - 1];
        if (pcColor[i] == 2) ch = (char)(ch + 32);
        bd[rankIdx][file] = ch;
    }

    int wpN = 0, bpN = 0;
    double wpSum = 0, bpSum = 0;
    BOOL illegal = NO;
    for (int r = 0; r < 8; r++) {
        for (int f = 0; f < 8; f++) {
            char ch = bd[r][f];
            if (ch == 'P') { wpSum += r; wpN++; if (r == 0) illegal = YES; }
            else if (ch == 'p') { bpSum += r; bpN++; if (r == 7) illegal = YES; }
        }
    }
    BOOL statInverted = (wpN >= 4 && bpN >= 4 && (wpSum / wpN) - (bpSum / bpN) > 2.0);
    if (illegal || statInverted) {
        char rot[8][8];
        for (int r = 0; r < 8; r++)
            for (int f = 0; f < 8; f++) rot[r][f] = bd[7 - r][7 - f];
        memcpy(bd, rot, sizeof(bd));
        flipped = !flipped;
        static int sLastCorrected = -1;
        if (sLastCorrected != (flipped ? 1 : 0)) {
            sLastCorrected = flipped ? 1 : 0;
            dbg([NSString stringWithFormat:@"orientation corrected -> flipped=%d", flipped]);
        }
    }

    gForcedFlip = flipped ? 1 : 0;

    NSMutableString *pl = [NSMutableString string];
    for (int r = 7; r >= 0; r--) {
        int empty = 0;
        for (int file = 0; file < 8; file++) {
            char ch = bd[r][file];
            if (!ch) { empty++; }
            else {
                if (empty) { [pl appendFormat:@"%d", empty]; empty = 0; }
                [pl appendFormat:@"%c", ch];
            }
        }
        if (empty) [pl appendFormat:@"%d", empty];
        if (r > 0) [pl appendString:@"/"];
    }

    if (gPuzzleCtx) gBotSide = flipped ? 1 : 0;

    NSString *startpos = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";
    if (![pl isEqualToString:gLastBotPlacement]) {
        if (gPuzzleCtx) {
        } else if ([pl isEqualToString:startpos]) {
            gBotSide = 0;
            if (gAccCount > 0) resetAccuracy();
            [gUciSeq setString:@""];
        } else if (gHavePrevBoard) {

            int whiteMoved = 0, blackMoved = 0;
            for (int r = 0; r < 8; r++) {
                for (int f = 0; f < 8; f++) {
                    char now = bd[r][f];
                    if (now != 0 && now != gPrevBotBoard[r][f]) {
                        if (now >= 'A' && now <= 'Z') whiteMoved++;
                        else                          blackMoved++;
                    }
                }
            }

            if (whiteMoved == 0 && blackMoved == 0) return nil;

            if (whiteMoved > 0 && blackMoved == 0)      gBotSide = 1;
            else if (blackMoved > 0 && whiteMoved == 0) gBotSide = 0;

        } else {
            gBotSide = flipped ? 1 : 0;
        }
        memcpy(gPrevBotBoard, bd, sizeof(bd));
        gHavePrevBoard = YES;
        gLastBotPlacement = [pl copy];
    }

    NSMutableString *cas = [NSMutableString string];
    if (bd[0][4] == 'K' && bd[0][7] == 'R') [cas appendString:@"K"];
    if (bd[0][4] == 'K' && bd[0][0] == 'R') [cas appendString:@"Q"];
    if (bd[7][4] == 'k' && bd[7][7] == 'r') [cas appendString:@"k"];
    if (bd[7][4] == 'k' && bd[7][0] == 'r') [cas appendString:@"q"];
    if (cas.length == 0) [cas setString:@"-"];

    if (outUserColor) *outUserColor = flipped ? 1 : 0;

    return [NSString stringWithFormat:@"%@ %@ %@ - 0 1",
            pl, gBotSide ? @"b" : @"w", cas];
}

static BOOL processBotBoard(UIView *board) {
    if (!board || !board.window) return NO;

    if (![NSStringFromClass([board class]) isEqualToString:@"SwiftChessBoard.ChessBoard"])
        return NO;
    if (!isBoardOnScreen(board)) return NO;
    gBotBoard = board;
    dumpMoveSelectors(board, @"board");

    BOOL inBotGame = NO;
    gPuzzleCtx = NO;
    UIResponder *pr = board;
    for (int pd = 0; pd < 14 && pr; pd++) {
        NSString *cn = NSStringFromClass([pr class]);
        if ([cn containsString:@"Puzzle"] || [cn containsString:@"Tactics"]) {
            inBotGame = YES; gPuzzleCtx = YES; break;
        }
        if ([cn containsString:@"PlayBot"] || [cn containsString:@"Coach"] ||
            [cn containsString:@"Lesson"]) { inBotGame = YES; break; }
        pr = [pr nextResponder];
    }
    if (!inBotGame) return NO;

    gOnlineGame = nil;
    gBoardView = board;
    gDrawBoard = board;
    int userColor = 0;
    NSString *fen = buildBotFEN(board, &userColor);
    if (!fen) return YES;

    setMyColor(userColor, @"processBotBoard");
    static NSString *sLastBotFen = nil;
    if (![fen isEqualToString:sLastBotFen]) {
        sLastBotFen = [fen copy];
        dbg([NSString stringWithFormat:@"BOT FEN: %@", fen]);
    }
    if (gBotSide == userColor) {
        fetchMove(fen);
    } else {
        clearArrow();
        analyzeUserMove(fen);
    }
    return YES;
}

static UIView *resolveDrawBoard(UIView *v) {
    UIView *cur = v;
    for (int i = 0; cur && i < 12; i++) {
        if ([NSStringFromClass([cur class]) isEqualToString:@"SwiftChessBoard.ChessBoard"])
            return cur;
        cur = cur.superview;
    }
    return v;
}

static NSString *buildPuzzleFENFromLabels(UIView *board) {
    if (!board || !board.window) return nil;
    CGRect boardRect = [board convertRect:board.bounds toView:nil];
    if (boardRect.size.width < 40) return nil;

    int flipped = -1;
    @try {
        SEL fs = NSSelectorFromString(@"isFlipped");
        if ([board respondsToSelector:fs]) flipped = ((BOOL (*)(id, SEL))objc_msgSend)(board, fs) ? 1 : 0;
    } @catch (NSException *e) {}

    char bd[8][8];
    memset(bd, 0, sizeof(bd));
    int count = 0;
    double wY = 0, bY = 0;
    int wN = 0, bN = 0;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:board.window];
    int visited = 0;
    while (stack.count && visited < 5000) {
        UIView *vw = [stack lastObject];
        [stack removeLastObject];
        visited++;
        for (UIView *sub in vw.subviews) [stack addObject:sub];

        NSString *al = nil;
        @try { al = vw.accessibilityLabel; } @catch (NSException *e) {}
        if (al.length < 7) continue;
        BOOL white;
        if ([al hasPrefix:@"White "]) white = YES;
        else if ([al hasPrefix:@"Black "]) white = NO;
        else continue;

        NSString *rest = [al substringFromIndex:6];
        if (rest.length < 3) continue;
        NSString *sq = [rest substringFromIndex:rest.length - 2];
        NSString *pieceName = [rest substringToIndex:rest.length - 2];
        unichar ff = [sq characterAtIndex:0], rr = [sq characterAtIndex:1];
        if (ff < 'a' || ff > 'h' || rr < '1' || rr > '8') continue;

        CGRect wf = [vw convertRect:vw.bounds toView:nil];
        if (!CGRectContainsPoint(boardRect, CGPointMake(CGRectGetMidX(wf), CGRectGetMidY(wf)))) continue;

        char pc = 0;
        if ([pieceName isEqualToString:@"Pawn"])   pc = 'P';
        else if ([pieceName isEqualToString:@"Knight"]) pc = 'N';
        else if ([pieceName isEqualToString:@"Bishop"]) pc = 'B';
        else if ([pieceName isEqualToString:@"Rook"])   pc = 'R';
        else if ([pieceName isEqualToString:@"Queen"])  pc = 'Q';
        else if ([pieceName isEqualToString:@"King"])   pc = 'K';
        else continue;
        if (!white) pc = (char)tolower(pc);

        int file = ff - 'a', rank = rr - '1';
        bd[rank][file] = pc;
        count++;
        if (white) { wY += CGRectGetMidY(wf); wN++; }
        else       { bY += CGRectGetMidY(wf); bN++; }
    }
    if (count < 2 || count > 32) return nil;

    int wk = 0, bk = 0;
    for (int r = 0; r < 8; r++)
        for (int f = 0; f < 8; f++) {
            if (bd[r][f] == 'K') wk++;
            else if (bd[r][f] == 'k') bk++;
        }
    if (wk != 1 || bk != 1) return nil;

    NSMutableString *pl = [NSMutableString string];
    for (int r = 7; r >= 0; r--) {
        int e = 0;
        for (int f = 0; f < 8; f++) {
            char c = bd[r][f];
            if (!c) { e++; }
            else { if (e) { [pl appendFormat:@"%d", e]; e = 0; } [pl appendFormat:@"%c", c]; }
        }
        if (e) [pl appendFormat:@"%d", e];
        if (r > 0) [pl appendString:@"/"];
    }

    NSMutableString *cas = [NSMutableString string];
    if (bd[0][4] == 'K' && bd[0][7] == 'R') [cas appendString:@"K"];
    if (bd[0][4] == 'K' && bd[0][0] == 'R') [cas appendString:@"Q"];
    if (bd[7][4] == 'k' && bd[7][7] == 'r') [cas appendString:@"k"];
    if (bd[7][4] == 'k' && bd[7][0] == 'r') [cas appendString:@"q"];
    if (!cas.length) [cas setString:@"-"];

    NSString *fenW = [NSString stringWithFormat:@"%@ w %@ - 0 1", pl, cas];
    NSString *fenB = [NSString stringWithFormat:@"%@ b %@ - 0 1", pl, cas];

    if (flipped == 1) return StockfishFenLegal([fenB UTF8String]) ? fenB : nil;
    if (flipped == 0) return StockfishFenLegal([fenW UTF8String]) ? fenW : nil;

    BOOL okW = StockfishFenLegal([fenW UTF8String]);
    BOOL okB = StockfishFenLegal([fenB UTF8String]);
    if (okW && !okB) return fenW;
    if (okB && !okW) return fenB;
    if (!okW && !okB) return nil;
    double wAvg = wN ? wY / wN : 0, bAvg = bN ? bY / bN : 0;
    return (bN && wN && bAvg > wAvg) ? fenB : fenW;
}

static BOOL drivePuzzle(UIView *board) {
    NSString *pf = buildPuzzleFENFromLabels(board);
    if (!pf.length) return NO;
    parseFEN(pf);
    setMyColor(gSide, @"drivePuzzle");
    static NSString *sLastPuzzleFen = nil;
    if (![pf isEqualToString:sLastPuzzleFen]) {
        sLastPuzzleFen = [pf copy];
        dbg([NSString stringWithFormat:@"PUZZLE FEN: %@", pf]);
    }
    gForcedFlip = -1;
    gDrawBoard = board;
    fetchMove(pf);
    return YES;
}

static void hook_layoutSubviews(id self, SEL _cmd) {

    Class c = [self class];
    while (c) {
        NSValue *origVal = gOrigLayouts[NSStringFromClass(c)];
        if (origVal) {
            OrigLayout orig = NULL;
            [origVal getValue:&orig];
            if (orig) orig(self, _cmd);
            break;
        }
        c = class_getSuperclass(c);
    }
    if (!gEnabled) return;

    UIView *boardSelf = (UIView *)self;
    if (!boardSelf.window) return;
    if (CGRectIsEmpty(boardSelf.bounds)) return;

    if (!isBoardOnScreen(boardSelf)) return;

    gBoardView = boardSelf;

    reassertArrow(gDrawBoard);
    updateEvalBar();

    NSDate *now = [NSDate date];
    if (gLastLayoutCheck && [now timeIntervalSinceDate:gLastLayoutCheck] < 0.5) return;
    gLastLayoutCheck = now;

    if (processBotBoard(boardSelf)) gBotSeen = [NSDate date];

    @try {
        typedef id (*IdGetter)(id, SEL);
        IdGetter getObj = (IdGetter)objc_msgSend;
        typedef NSString *(*StrGetter)(id, SEL);
        StrGetter strGet = (StrGetter)objc_msgSend;
        typedef NSInteger (*IntGetter)(id, SEL);
        IntGetter getInt = (IntGetter)objc_msgSend;

        static NSInteger gLastRawColor = -99;
        SEL colorSel = NSSelectorFromString(@"myPieceColor");
        if ([self respondsToSelector:colorSel]) {

            gOnlineDrawBoard = boardSelf;
            NSInteger raw = getInt(self, colorSel);
            if (raw != gLastRawColor) {
                gLastRawColor = raw;
                dbg([NSString stringWithFormat:@"myPieceColor raw=%ld", (long)raw]);
            }

            if (raw == 1) setMyColor(0, [NSString stringWithFormat:@"myPieceColor raw=1 %@", NSStringFromClass([self class])]);
            else if (raw == 2) setMyColor(1, [NSString stringWithFormat:@"myPieceColor raw=2 %@", NSStringFromClass([self class])]);
            else if (raw == 0) {

                SEL flipSel = NSSelectorFromString(@"isFlipped");
                if ([self respondsToSelector:flipSel]) {
                    typedef BOOL (*BoolGetter)(id, SEL);
                    BOOL flipped = ((BoolGetter)objc_msgSend)(self, flipSel);
                    setMyColor(flipped ? 1 : 0, [NSString stringWithFormat:@"raw=0 isFlipped=%d %@", flipped, NSStringFromClass([self class])]);
                }
            }
        } else {

            SEL flipSel2 = NSSelectorFromString(@"isFlipped");
            if ([self respondsToSelector:flipSel2]) {
                typedef BOOL (*BoolGetter)(id, SEL);
                BOOL flipped = ((BoolGetter)objc_msgSend)(self, flipSel2);
                NSInteger newColor = flipped ? 1 : 0;
                if (newColor != gMyColor) {
                    setMyColor(newColor, [NSString stringWithFormat:@"isFlipped-only %@", NSStringFromClass([self class])]);
                    dbg([NSString stringWithFormat:@"color via isFlipped: %@",
                         flipped ? @"black" : @"white"]);
                }
            } else {
                static BOOL gLoggedNoColor = NO;
                if (!gLoggedNoColor) {
                    gLoggedNoColor = YES;
                    dbg(@"WARN: board has no myPieceColor or isFlipped");
                }
            }
        }

        NSArray *gameSelNames = @[@"game", @"chessGame", @"puzzle", @"currentGame",
                                  @"gameModel", @"chessBoardModel", @"boardModel",
                                  @"viewModel", @"botGame", @"playGame", @"activeGame",
                                  @"coachGame", @"lessonGame", @"practiceGame"];
        UIResponder *resp = [(UIView *)self nextResponder];
        id game = nil;
        int chainDepth = 0;
        static NSString *gLoggedChainVC = nil;
        NSMutableString *chainLog = [NSMutableString string];

        while (resp && chainDepth < 20) {
            [chainLog appendFormat:@"%@→", NSStringFromClass([resp class])];
            for (NSString *selName in gameSelNames) {
                SEL sel = NSSelectorFromString(selName);
                if ([resp respondsToSelector:sel]) {
                    @try {
                        id obj = getObj(resp, sel);
                        if (obj) {
                            game = obj;
                            NSString *vcName = NSStringFromClass([resp class]);
                            if (![vcName isEqualToString:gLoggedChainVC]) {
                                gLoggedChainVC = vcName;
                                dbg([NSString stringWithFormat:@"game via .%@ on %@ (class: %@)",
                                     selName, vcName, NSStringFromClass([obj class])]);
                            }
                            break;
                        }
                    } @catch (NSException *e) {}
                }
            }
            if (game) break;
            resp = [resp nextResponder];
            chainDepth++;
        }

        NSString *currentFEN = nil;

        if (game) {
            SEL encSel = NSSelectorFromString(@"encodedMoves");
            if ([game respondsToSelector:encSel]) {
                gOnlineGame = game;
                dumpMoveSelectors(game, @"game");
                gOnlineSeen = [NSDate date];
                gBotBoard = nil;
                NSString *encoded = strGet(game, encSel);
                NSString *encKey = encoded.length ? encoded : @"__EMPTY__";
                if ([encKey isEqualToString:gLastEncoded]) return;
                gLastEncoded = [encKey copy];

                SEL iFenSel = NSSelectorFromString(@"initialFEN");
                NSString *initialFEN = nil;
                if ([game respondsToSelector:iFenSel]) initialFEN = strGet(game, iFenSel);
                if (!initialFEN.length) initialFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
                currentFEN = decodeTCNToFEN(initialFEN, encoded);
            }
        }

        if (!currentFEN && gHookedEngine) {
            SEL hFenSel = NSSelectorFromString(@"getCurrentFen");
            if ([gHookedEngine respondsToSelector:hFenSel]) {
                @try {
                    typedef NSString *(*StrGetter2)(id, SEL);
                    NSString *hfen = ((StrGetter2)objc_msgSend)(gHookedEngine, hFenSel);
                    if (hfen.length > 10 && [hfen containsString:@"/"]) {
                        if ([hfen isEqualToString:gLastEncoded]) return;
                        gLastEncoded = [hfen copy];
                        parseFEN(hfen);
                        currentFEN = hfen;
                        static BOOL gLoggedHk = NO;
                        if (!gLoggedHk) {
                            gLoggedHk = YES;
                            dbg([NSString stringWithFormat:@"FEN via hooked %@",
                                 NSStringFromClass([gHookedEngine class])]);
                        }
                    }
                } @catch (NSException *e) {}
            }
        }

        if (!currentFEN) {

            NSMutableArray *probeTargets = [NSMutableArray array];

            NSArray *linkProps = @[@"delegate", @"dataSource", @"boardOwner", @"owner",
                                    @"coordinator", @"interactor", @"presenter"];
            for (NSString *lp in linkProps) {
                SEL lpSel = NSSelectorFromString(lp);
                if ([self respondsToSelector:lpSel]) {
                    @try {
                        id linked = getObj(self, lpSel);
                        if (linked) [probeTargets addObject:linked];
                    } @catch (NSException *e) {}
                }
            }

            UIResponder *r2 = [(UIView *)self nextResponder];
            int d2 = 0;
            while (r2 && d2 < 15) {
                [probeTargets addObject:r2];
                r2 = [r2 nextResponder];
                d2++;
            }

            SEL fenSel = NSSelectorFromString(@"getCurrentFen");
            NSArray *controllerProps = @[@"gameController", @"chessGameController",
                                         @"engineController", @"interactor", @"boardOwner"];

            for (id target in probeTargets) {

                if ([target respondsToSelector:fenSel]) {
                    @try {
                        NSString *fen = strGet(target, fenSel);
                        if (fen.length > 10 && [fen containsString:@"/"]) {
                            if ([fen isEqualToString:gLastEncoded]) return;
                            gLastEncoded = [fen copy];
                            parseFEN(fen);
                            currentFEN = fen;
                            static BOOL gLoggedEngine = NO;
                            if (!gLoggedEngine) {
                                gLoggedEngine = YES;
                                dbg([NSString stringWithFormat:@"FEN via getCurrentFen on %@",
                                     NSStringFromClass([target class])]);
                            }
                            break;
                        }
                    } @catch (NSException *e) {}
                }

                for (NSString *cp in controllerProps) {
                    SEL cpSel = NSSelectorFromString(cp);
                    if (![target respondsToSelector:cpSel]) continue;
                    @try {
                        id controller = getObj(target, cpSel);
                        if (!controller) continue;

                        if ([controller respondsToSelector:fenSel]) {
                            NSString *fen = strGet(controller, fenSel);
                            if (fen.length > 10 && [fen containsString:@"/"]) {
                                if ([fen isEqualToString:gLastEncoded]) return;
                                gLastEncoded = [fen copy];
                                parseFEN(fen);
                                currentFEN = fen;
                                static BOOL gLoggedCtrl = NO;
                                if (!gLoggedCtrl) {
                                    gLoggedCtrl = YES;
                                    dbg([NSString stringWithFormat:@"FEN via .%@.getCurrentFen on %@",
                                         cp, NSStringFromClass([target class])]);
                                }
                            }
                        }

                        if (!currentFEN) {
                            SEL encSel2 = NSSelectorFromString(@"encodedMoves");
                            if ([controller respondsToSelector:encSel2]) {
                                if (!game) game = controller;
                            }
                        }
                    } @catch (NSException *e) {}
                    if (currentFEN) break;
                }
                if (currentFEN) break;
            }
        }

        if (!currentFEN) {
            NSArray *fenSelNames = @[@"fen", @"currentFEN", @"fenString", @"position",
                                     @"boardFEN", @"fenAfterMove", @"currentPosition",
                                     @"positionFEN", @"boardPosition", @"gameFEN",
                                     @"getCurrentFen"];

            NSMutableArray *targets = [NSMutableArray arrayWithObject:self];
            UIResponder *r3 = [(UIView *)self nextResponder];
            int d3 = 0;
            while (r3 && d3 < 15) {
                [targets addObject:r3];
                r3 = [r3 nextResponder];
                d3++;
            }

            for (id target in targets) {
                for (NSString *selName in fenSelNames) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([target respondsToSelector:sel]) {
                        @try {
                            id result = getObj(target, sel);
                            if ([result isKindOfClass:[NSString class]] && [result length] > 10
                                && [result containsString:@"/"]) {
                                NSString *fen = (NSString *)result;
                                if ([fen isEqualToString:gLastEncoded]) return;
                                gLastEncoded = [fen copy];
                                parseFEN(fen);
                                currentFEN = fen;
                                static NSString *gLoggedFenSrc = nil;
                                NSString *src = [NSString stringWithFormat:@".%@ on %@", selName, NSStringFromClass([target class])];
                                if (![src isEqualToString:gLoggedFenSrc]) {
                                    gLoggedFenSrc = src;
                                    dbg([NSString stringWithFormat:@"FEN via %@", src]);
                                }
                                break;
                            }
                        } @catch (NSException *e) {}
                    }
                }
                if (currentFEN) break;
            }
        }

        if (!game && !currentFEN) {
            static NSString *gLastFailChain = nil;
            static NSDate *gLastFailLog = nil;
            BOOL shouldLog = NO;
            if (![chainLog isEqualToString:gLastFailChain]) shouldLog = YES;
            if (gLastFailLog && [[NSDate date] timeIntervalSinceDate:gLastFailLog] > 10.0) shouldLog = YES;
            if (!gLastFailLog) shouldLog = YES;
            if ([chainLog containsString:@"Puzzle"] && [NSStringFromClass([self class]) hasPrefix:@"CH"]) {
                gPuzzleBoard = (UIView *)self;
                if (drivePuzzle((UIView *)self)) return;
            }
            if (shouldLog && chainLog.length) {
                gLastFailChain = [chainLog copy];
                gLastFailLog = [NSDate date];
                dbg([NSString stringWithFormat:@"no game/FEN in chain: %@", chainLog]);
            }
            return;
        }

        if (!currentFEN) return;

        if (currentFEN.length) {

            if (gMyColor >= 0 && gMyColor != gSide) {

                dispatch_async(dispatch_get_main_queue(), ^{ clearArrow(); });
                return;
            }
            dbg([NSString stringWithFormat:@"FEN: %@", [currentFEN substringToIndex:MIN(currentFEN.length, 55)]]);
            gForcedFlip = -1;

            gDrawBoard = gOnlineDrawBoard ?: resolveDrawBoard(boardSelf);
            fetchMove(currentFEN);
        }
    } @catch (NSException *ex) {
        dbg([NSString stringWithFormat:@"layout err: %@", ex.reason]);
    }
}

typedef void (*OrigSetEncoded)(id, SEL, NSString *);
static OrigSetEncoded gOrigSetEncoded = NULL;

static void hook_setEncodedMoves(id self, SEL _cmd, NSString *encoded) {
    if (gOrigSetEncoded) gOrigSetEncoded(self, _cmd, encoded);
    if (!gEnabled) return;
    if (!encoded) encoded = @"";
    @try {
        gOnlineGame = self;
        gOnlineSeen = [NSDate date];
        dumpMoveSelectors(self, @"game");
        typedef NSString *(*StrGetter)(id, SEL);
        StrGetter strGet = (StrGetter)objc_msgSend;
        SEL iFenSel = NSSelectorFromString(@"initialFEN");
        NSString *initialFEN = nil;
        if ([self respondsToSelector:iFenSel]) initialFEN = strGet(self, iFenSel);
        if (!initialFEN.length) initialFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        NSString *currentFEN = decodeTCNToFEN(initialFEN, encoded);
        if (currentFEN.length) {
            parseFEN(currentFEN);
            if (gMyColor >= 0 && gMyColor != gSide) return;
            dbg([NSString stringWithFormat:@"FEN(setter): %@", [currentFEN substringToIndex:MIN(currentFEN.length, 55)]]);
            gForcedFlip = -1;
            dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(currentFEN); });
        }
    } @catch (NSException *ex) {
        dbg([NSString stringWithFormat:@"setter err: %@", ex.reason]);
    }
}

@interface CHAppDelegate : NSObject
- (void)applicationDidBecomeActive:(id)app;
@end

%hook CHAppDelegate
- (void)applicationDidBecomeActive:(id)app {
    %orig;
    loadPrefs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        setupFloatingButton();

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d boolForKey:PREF_SHOWN] || ![d boolForKey:PREF_CREDIT2]) {
            [d setBool:YES forKey:PREF_SHOWN];
            [d setBool:YES forKey:PREF_CREDIT2];
            [d synchronize];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showCredits();
            });
        }
    });
}
%end

static void installBoardHooks(void) {
    NSArray *boardClassNames = @[
        @"CHBoardView",
        @"CHSoloBoardView",
        @"CHSimpleBoardView",
        @"CHDiagramBoardView",
        @"CHAnalysisBoardView"
    ];
    SEL layoutSel = @selector(layoutSubviews);
    for (NSString *name in boardClassNames) {
        if (gOrigLayouts[name]) continue;
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        Method m = class_getInstanceMethod(cls, layoutSel);
        if (!m) continue;

        OrigLayout orig = NULL;
        MSHookMessageEx(cls, layoutSel, (IMP)hook_layoutSubviews, (IMP *)&orig);
        if (orig) {
            gOrigLayouts[name] = [NSValue valueWithBytes:&orig objCType:@encode(OrigLayout)];
        }
        dbg([NSString stringWithFormat:@"HOOKED layoutSubviews on %@", name]);
    }

    static BOOL sSwiftBoardHooked = NO;
    if (!sSwiftBoardHooked) {
        unsigned int scCount = 0;
        Class *scClasses = objc_copyClassList(&scCount);
        for (unsigned int i = 0; i < scCount; i++) {
            NSString *scName = NSStringFromClass(scClasses[i]);

            if ([scName containsString:@"SwiftChessBoard"] &&
                ([scName containsString:@"BoardView"] || [scName hasSuffix:@"ChessBoard"])) {
                if (gOrigLayouts[scName]) { sSwiftBoardHooked = YES; continue; }
                Method m = class_getInstanceMethod(scClasses[i], layoutSel);
                if (!m) continue;
                OrigLayout orig = NULL;
                MSHookMessageEx(scClasses[i], layoutSel, (IMP)hook_layoutSubviews, (IMP *)&orig);
                if (orig) {
                    gOrigLayouts[scName] = [NSValue valueWithBytes:&orig objCType:@encode(OrigLayout)];
                }
                dbg([NSString stringWithFormat:@"HOOKED layoutSubviews on %@ (SwiftBoard)", scName]);
                sSwiftBoardHooked = YES;
            }
        }
        free(scClasses);
    }

    static BOOL sSwiftFenHooked = NO;
    if (!sSwiftFenHooked) {

        if (!gSwiftStringBridge) {
            gSwiftStringBridge = (SwiftStringBridgeFunc)dlsym(RTLD_DEFAULT,
                "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            if (gSwiftStringBridge) {
                dbg(@"Found Swift String bridge");
            } else {
                dbg(@"WARN: Swift String bridge NOT found");
            }
        }

        NSArray *fenSymbols = @[
            @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyF",
            @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTo",
            @"$s16EngineController04ChessB0C13getCurrentFenSSyF",
            @"$s16EngineController04ChessbC0C13getCurrentFenSSyF",
        ];
        for (NSString *sym in fenSymbols) {
            void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
            if (ptr) {
                MSHookFunction(ptr, (void *)hook_swiftGetFen, (void **)&gOrigSwiftGetFen);
                gSwiftHookActive = YES;
                sSwiftFenHooked = YES;
                dbg([NSString stringWithFormat:@"HOOKED Swift getCurrentFen: %@", sym]);
                break;
            }
        }

        if (!sSwiftFenHooked) {
            NSArray *tcnSymbols = @[
                @"$s16EngineController19ChessGameControllerC20getMainLineTcnStringSSyF",
                @"$s16EngineController04ChessB0C20getMainLineTcnStringSSyF",
            ];
            for (NSString *sym in tcnSymbols) {
                void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
                if (ptr) {
                    MSHookFunction(ptr, (void *)hook_swiftGetTcn, (void **)&gOrigSwiftGetTcn);
                    gSwiftHookActive = YES;
                    sSwiftFenHooked = YES;
                    dbg([NSString stringWithFormat:@"HOOKED Swift getMainLineTcnString: %@", sym]);
                    break;
                }
            }
        }

        if (!sSwiftFenHooked) {

            NSArray *broadSymbols = @[

                @"$s15ChessPlayBot19ChessGameControllerC13getCurrentFenSSyF",
                @"$s5Chess19ChessGameControllerC13getCurrentFenSSyF",
                @"$s9ChessGame19ChessGameControllerC13getCurrentFenSSyF",

                @"$s16EngineController14GameControllerC13getCurrentFenSSyF",
                @"$s16EngineController0B0C13getCurrentFenSSyF",

                @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTj",
                @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTq",
            ];
            for (NSString *sym in broadSymbols) {
                void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
                if (ptr) {
                    MSHookFunction(ptr, (void *)hook_swiftGetFen, (void **)&gOrigSwiftGetFen);
                    gSwiftHookActive = YES;
                    sSwiftFenHooked = YES;
                    dbg([NSString stringWithFormat:@"HOOKED Swift FEN (broad): %@", sym]);
                    break;
                }
            }
        }

    }

    static BOOL sEncodedHooked = NO;
    if (!sEncodedHooked) {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        SEL target = NSSelectorFromString(@"setEncodedMoves:");
        for (unsigned int i = 0; i < count; i++) {
            if (class_getInstanceMethod(classes[i], target)) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name hasPrefix:@"UI"] || [name hasPrefix:@"NS"] || [name hasPrefix:@"_"]) continue;
                MSHookMessageEx(classes[i], target, (IMP)hook_setEncodedMoves, (IMP *)&gOrigSetEncoded);
                dbg([NSString stringWithFormat:@"HOOKED setEncodedMoves: on %@", name]);
                sEncodedHooked = YES;
                break;
            }
        }
        free(classes);
    }
}

%ctor {
    gLoadTime = [NSDate date];
    gOrigLayouts = [NSMutableDictionary dictionary];
    loadPrefs();
    dbg(@"loaded v2.5.2 (SF18 + Maia3)");
    EngineStart();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *candidates = maiaCandidatePaths();
        __block BOOL found = NO;
        for (NSString *c in candidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:c]) {
                found = YES;
                BOOL ok = MaiaLoad([c UTF8String]);
                dbg([NSString stringWithFormat:@"maia load %@: %@", ok ? @"OK" : @"FAIL", c]);
                break;
            }
        }
        if (!found) {
            dbg(@"maia: model not on disk — using embedded copy");
            BOOL ok = MaiaLoadEmbedded();
            dbg([NSString stringWithFormat:@"maia embedded load: %@", ok ? @"OK" : @"FAIL"]);
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            enginePollTick();
        }];
        dbg(@"engine poller started");

    });
}
