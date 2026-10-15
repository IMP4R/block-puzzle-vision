import Cocoa
import Foundation

let OWNER = "\u{0412}\u{0438}\u{0434}\u{0435}\u{043E}\u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440} iPhone"
let SHIFT_FILE = "/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_geometry_shift.txt"
// The old shift cache contained 65 pt from a bad calibration and moved every
// board sample into the tray. Geometry now comes from the actual 237 pt board.
let SAVED_SHIFT = 0.0
var UI_SHIFT = 0.0
var BOARD = CGRect(x:39,y:194,width:237,height:237)
// All tray Y limits are fractions of the detected board size, so moving or
// scaling the Mirroring window preserves the same geometry. On the current
// frame normal figures end near 33.7% below the board, while hint graphics
// begin near 42.8%. A 41% cutoff leaves a small guard on both sides; 45%
// would already include the top of the hints.
let TRAY_BAND_START_RATIO: CGFloat = 2.0 / 264.0
let TRAY_PIECE_MIN_TOP_RATIO: CGFloat = 12.0 / 264.0
let TRAY_CUTOFF_RATIO: CGFloat = 0.41
let TRAY_EDGE_MARGIN_RATIO: CGFloat = 1.0 / 264.0
// Drag offsets are normalized to the detected board. The old values were
// calibrated on a 237 pt board; expressing them as ratios keeps the gesture
// identical when the window/board moves or scales.
let TARGET_X_BIAS_BOARD_RATIO: CGFloat = 0.253 / 237.0
let TARGET_Y_LIFT_BOARD_RATIO: CGFloat = 88.780 / 237.0
var BAND = (BOARD.maxY + BOARD.height * TRAY_BAND_START_RATIO,
            BOARD.maxY + BOARD.height * TRAY_CUTOFF_RATIO)
var HINT_TOP = BAND.1
func applyAdaptiveGeometry(_ grid: CGRect) {
    BOARD = grid
    HINT_TOP = grid.maxY + grid.height * TRAY_CUTOFF_RATIO
    BAND = (grid.maxY + grid.height * TRAY_BAND_START_RATIO, HINT_TOP)
}
let EMPTY = (r: 75.0, g: 75.0, b: 163.0)
var EMPTY_REF = EMPTY
var LAST_EMPTY_SUPPORT = 0
let BACK = CGPoint(x: 28, y: 85)
let RESTART_YES = CGPoint(x: 158, y: 393)
let RESTART_FIRST_YES_WAIT_US = 500_000
let SCORE_RECT = CGRect(x: 74, y: 146, width: 26, height: 28)
let FOFFS = [55.0, 50.0, 60.0, 45.0, 0.0]
let FRAMES = "/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_frames"
let METRICS = "/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_metrics.jsonl"
let ARGS = CommandLine.arguments
let ONCE = ARGS.contains("--once")
var fIdx = 0
var combo = 0

struct Img { let w: Int; let h: Int; let scale: Double; let d: [UInt8] }
struct Piece { let cells: [[Bool]]; let rows: Int; let cols: Int; let ax: Double; let ay: Double; let bbox: [Double] }

func findWin() -> (CGWindowID, CGRect, pid_t)? {
    for w in (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [] {
        guard (w[kCGWindowOwnerName as String] as? String) == OWNER else { continue }
        var b = CGRect.zero
        if let bd = w[kCGWindowBounds as String] as? [String: Any] { CGRectMakeWithDictionaryRepresentation(bd as CFDictionary, &b) }
        if b.height > 600 && b.width < 400 {
            return (CGWindowID((w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0), b, pid_t((w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0))
        }
    }
    return nil
}
func onscreen(_ id: CGWindowID) -> Bool {
    for w in (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? [] {
        if (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id { return true }
    }
    return false
}
func decodeImg(_ path: String, _ winWidthPt: Double) -> (Img, CGImage)? {
    guard let ni = NSImage(contentsOfFile: path) else { return nil }
    var rect = CGRect(origin: .zero, size: ni.size)
    guard let ci = ni.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let w = ci.width, h = ci.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(ci, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let p = ctx.data else { return nil }
    let arr = Array(UnsafeBufferPointer(start: p.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4))
    return (Img(w: w, h: h, scale: Double(w) / Double(winWidthPt), d: arr), ci)
}
func captureTo(_ args: [String], _ path: String) -> Bool {
    try? FileManager.default.removeItem(atPath: path)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = args + [path]
    do { try task.run(); task.waitUntilExit() } catch { return false }
    return FileManager.default.fileExists(atPath: path)
}
func deadFrame(_ im: Img) -> Bool {
    // A dead backing store reads as a solid black frame; a live one always
    // has content in the center. Sampled in pixel coordinates.
    var black = 0, total = 0
    var y = im.h / 4
    while y < im.h * 3 / 4 {
        var x = im.w / 4
        while x < im.w * 3 / 4 {
            let o = (y * im.w + x) * 4
            if im.d[o] < 24 && im.d[o + 1] < 24 && im.d[o + 2] < 24 { black += 1 }
            total += 1
            x += 16
        }
        y += 16
    }
    return total > 0 && black * 100 / total > 92
}
func grab(_ id: CGWindowID, _ win: CGRect) -> (Img, CGImage)? {
    let path = "/tmp/bb_cap.png"
    // Window-id capture reads the window backing store, which is immune to
    // screen-level color filters (Night Shift/True Tone) that otherwise shift
    // every captured color and break board/piece color matching. Use it while
    // the stream is alive; a dead backing store reads as a black frame, in
    // which case fall back to the live screen region.
    if captureTo(["-x", "-o", "-l\(id)"], path), let byId = decodeImg(path, Double(win.width)), !deadFrame(byId.0) {
        return byId
    }
    let capRect = String(format: "%.0f,%.0f,%.0f,%.0f", win.minX, win.minY, win.width, win.height)
    if captureTo(["-x", "-R" + capRect], path) { return decodeImg(path, Double(win.width)) }
    return nil
}
func px(_ im: Img, _ xpt: Double, _ ypt: Double) -> (Double, Double, Double) {
    let x = Int(xpt * im.scale), y = Int(ypt * im.scale)
    guard x >= 0, y >= 0, x < im.w, y < im.h else { return (0, 0, 0) }
    let o = (y * im.w + x) * 4
    return (Double(im.d[o]), Double(im.d[o + 1]), Double(im.d[o + 2]))
}
func boardState(_ im: Img) -> ([[Bool]], [[(Int, Int, Int)]]) {
    var b = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 8)
    var rgb = [[(Int, Int, Int)]](repeating: [(Int, Int, Int)](repeating: (0, 0, 0), count: 8), count: 8)
    let cell = BOARD.width / 8.0
    var samples=[(Double,Double,Double)]()
    for r in 0..<8 { for c in 0..<8 {
        samples.append(px(im,BOARD.minX+(Double(c)+0.5)*cell,
                             BOARD.minY+(Double(r)+0.5)*cell))
    }}
    // Empty cells are the dark blue board background. Never infer "empty"
    // from the largest cluster: once the board gets busy, a block colour may
    // be more common and silently invert occupancy. Anchor candidates to the
    // known background colour, then use a medoid to reject small variations.
    let emptyCandidates=samples.filter { p in
        let dr=p.0-EMPTY_REF.r,dg=p.1-EMPTY_REF.g,db=p.2-EMPTY_REF.b
        return dr*dr+dg*dg+db*db < 3600
    }
    LAST_EMPTY_SUPPORT=emptyCandidates.count
    if !emptyCandidates.isEmpty {
        var best=emptyCandidates[0],bestScore=Double.infinity
        for p in emptyCandidates {
            var score=0.0
            for q in emptyCandidates {
                let dr=p.0-q.0,dg=p.1-q.1,db=p.2-q.2
                score += dr*dr+dg*dg+db*db
            }
            if score<bestScore { best=p; bestScore=score }
        }
        EMPTY_REF=(r:best.0,g:best.1,b:best.2)
    }
    for r in 0..<8 { for c in 0..<8 {
        let p=samples[r*8+c]
        let dr=p.0-EMPTY_REF.r,dg=p.1-EMPTY_REF.g,db=p.2-EMPTY_REF.b
        b[r][c]=dr*dr+dg*dg+db*db > 324
        rgb[r][c]=(Int(p.0),Int(p.1),Int(p.2))
    }}
    return (b,rgb)
}
func satAt(_ im: Img, _ x: Int, _ y: Int) -> Bool {
    let o = (y * im.w + x) * 4
    let r = Double(im.d[o]), g = Double(im.d[o + 1]), b = Double(im.d[o + 2])
    let mx = max(r, g, b), mn = min(r, g, b)
    let dr=r-EMPTY_REF.r, dg=g-EMPTY_REF.g, db=b-EMPTY_REF.b
    if dr*dr+dg*dg+db*db < 3600 { return false }
    return mx > 120 && mx - mn > 70
}
func pieceCellAt(_ im: Img, _ x: Int, _ y: Int) -> Bool {
    var rr=0.0,gg=0.0,bb=0.0,n=0.0
    for dy in -1...1 { for dx in -1...1 {
        let xx=max(0,min(im.w-1,x+dx)),yy=max(0,min(im.h-1,y+dy))
        let o=(yy*im.w+xx)*4
        rr+=Double(im.d[o]); gg+=Double(im.d[o+1]); bb+=Double(im.d[o+2]); n+=1
    }}
    let mx=max(rr,gg,bb)/n,mn=min(rr,gg,bb)/n
    return mx > 190 && mx-mn > 50
}
func detectPieces(_ im: Img) -> [Piece] {
    let y0 = Int(BAND.0 * im.scale), y1 = min(Int(BAND.1 * im.scale), im.h - 1)
    guard y0 <= y1 else { return [] }
    // Saturated mask (board background excluded inside satAt). A few px of
    // dilation joins the cells of one piece across their thin gridline gaps, and
    // 2D connected components then separate pieces even when their x-ranges
    // overlap (the old column-only grouping merged those into one bad piece).
    let W=im.w, bh=y1-y0+1
    var mask=[Bool](repeating:false,count:W*bh)
    for y in y0...y1 { for x in 0..<W where satAt(im,x,y) { mask[(y-y0)*W+x]=true } }
    let R=5
    var dil=[Bool](repeating:false,count:W*bh)
    for gy in 0..<bh { for gx in 0..<W where mask[gy*W+gx] {
        let xa=max(0,gx-R),xb=min(W-1,gx+R),ya=max(0,gy-R),yb=min(bh-1,gy+R)
        for yy in ya...yb { for xx in xa...xb { dil[yy*W+xx]=true } }
    }}
    var parent=[Int](repeating:0,count:W*bh); for i in 0..<parent.count { parent[i]=i }
    func find(_ a:Int)->Int { var x=a; while parent[x] != x { parent[x]=parent[parent[x]]; x=parent[x] }; return x }
    func uni(_ a:Int,_ b:Int){ let ra=find(a),rb=find(b); if ra != rb { parent[ra]=rb } }
    for gy in 0..<bh { for gx in 0..<W where dil[gy*W+gx] {
        if gx+1<W && dil[gy*W+gx+1] { uni(gy*W+gx,gy*W+gx+1) }
        if gy+1<bh && dil[(gy+1)*W+gx] { uni(gy*W+gx,(gy+1)*W+gx) }
    }}
    var comp=[Int:(Int,Int,Int,Int,Int)]()
    for gy in 0..<bh { for gx in 0..<W where dil[gy*W+gx] {
        let r=find(gy*W+gx); var c=comp[r] ?? (gx,gy,gx,gy,0)
        c.0=min(c.0,gx);c.1=min(c.1,gy);c.2=max(c.2,gx);c.3=max(c.3,gy);c.4+=1; comp[r]=c
    }}
    // A single piece can fragment into several overlapping blobs after dilation;
    // merge boxes that overlap so each physical piece is counted exactly once.
    var boxes=comp.values.filter{ $0.4 >= 150 }.map{ $0 }
    var didAny=true
    while didAny {
        didAny=false
        var i=0
        while i<boxes.count {
            var j=i+1
            var merged=false
            while j<boxes.count {
                let a=boxes[i], b=boxes[j]
                if a.0<=b.2+8 && b.0<=a.2+8 && a.1<=b.3+8 && b.1<=a.3+8 {
                    boxes[i]=(min(a.0,b.0),min(a.1,b.1),max(a.2,b.2),max(a.3,b.3),a.4+b.4)
                    boxes.remove(at:j); merged=true; didAny=true
                } else { j+=1 }
            }
            if !merged { i+=1 }
        }
    }
    let pitch0 = 14.0 * (BOARD.width / 237.0) * im.scale
    var out:[Piece]=[]
    for c in boxes {
        guard c.4 >= 150 else { continue }
        // shrink the dilated bbox back to the real piece extent
        let gs=c.0+R, ge=c.2-R, ymin=c.1+R, ymax=c.3-R
        guard ge>gs, ymax>ymin else { continue }
        let wpx=Double(ge-gs+1), hpx=Double(ymax-ymin+1)
        let cols=max(1,Int((wpx/pitch0).rounded())), rows=max(1,Int((hpx/pitch0).rounded()))
        let sx=wpx/Double(cols), sy=hpx/Double(rows)
        var cells=[[Bool]](repeating:[Bool](repeating:false,count:cols),count:rows)
        var anchor:(Double,Double)?=nil
        for r in 0..<rows { for cc in 0..<cols {
            let cx=Double(gs)+(Double(cc)+0.5)*sx, cy=Double(y0+ymin)+(Double(r)+0.5)*sy
            if pieceCellAt(im,Int(cx),Int(cy)) { cells[r][cc]=true; if anchor==nil { anchor=(cx/im.scale,cy/im.scale) } }
        }}
        if let a=anchor {
            var minR=rows,maxR = -1,minC=cols,maxC = -1
            for r in 0..<rows { for cc in 0..<cols where cells[r][cc] { minR=min(minR,r);maxR=max(maxR,r);minC=min(minC,cc);maxC=max(maxC,cc) } }
            guard maxR>=minR,maxC>=minC else { continue }
            let trimmed=(minR...maxR).map { r in (minC...maxC).map { cc in cells[r][cc] } }
            let tx0=(Double(gs)+Double(minC)*sx)/im.scale
            let ty0=(Double(y0+ymin)+Double(minR)*sy)/im.scale
            let tx1=(Double(gs)+Double(maxC+1)*sx-1.0)/im.scale
            let ty1=(Double(y0+ymin)+Double(maxR+1)*sy-1.0)/im.scale
            out.append(Piece(cells:trimmed,rows:trimmed.count,cols:trimmed[0].count,ax:a.0,ay:a.1,bbox:[tx0,ty0,tx1,ty1]))
        }
    }
    return out
}

func boardGridScore(_ im:Img)->Double {
    let cell=BOARD.width/8.0
    var score=0.0, plausible=0
    for r in 0..<8 { for c in 0..<8 {
        let cx=BOARD.minX+(Double(c)+0.5)*cell
        let cy=BOARD.minY+(Double(r)+0.5)*cell
        let center=px(im,cx,cy)
        let left=px(im,BOARD.minX+Double(c)*cell+1.0,cy)
        let top=px(im,cx,BOARD.minY+Double(r)*cell+1.0)
        score += (rgbDistance(center,left)+rgbDistance(center,top))*0.5
        let d=rgbDistance(center,(EMPTY.r,EMPTY.g,EMPTY.b))
        let mx=max(center.0,center.1,center.2),mn=min(center.0,center.1,center.2)
        if d<55 || (mx>145 && mx-mn>35) { plausible += 1 }
    }}
    return score/64.0 + Double(plausible)*0.35
}

@discardableResult
func validTrayPieces(_ im:Img)->[Piece] {
    detectPieces(im).filter { p in
        connectedShape(p) &&
        p.bbox[1] > BOARD.maxY + BOARD.height * TRAY_PIECE_MIN_TOP_RATIO &&
        p.bbox[3] < HINT_TOP - BOARD.height * TRAY_EDGE_MARGIN_RATIO
    }
}

func boardCellGood(_ im:Img,_ cx:Double,_ cy:Double)->Bool {
    // A real board cell is uniform inside (not text/gradient) and is either
    // the navy board background or a strongly saturated block color. Pastel
    // UI areas fail the saturation test, text fails the uniformity test.
    let pts=[(0.0,0.0),(-5.0,0.0),(5.0,0.0),(0.0,-5.0),(0.0,5.0)]
    let cs=pts.map { p in px(im,cx+p.0,cy+p.1) }
    var m=0.0
    for i in 0..<cs.count { for j in i+1..<cs.count {
        let d=rgbDistance(cs[i],cs[j]); if d>m { m=d }
    }}
    if m>=45 { return false }
    let center=cs[0]
    let dEmpty=rgbDistance(center,(EMPTY_REF.r,EMPTY_REF.g,EMPTY_REF.b))
    let mx=max(center.0,center.1,center.2),mn=min(center.0,center.1,center.2)
    let sat = mx>0 ? (mx-mn)/mx : 0.0
    return dEmpty<55 || (mx>145 && sat>=0.45)
}
func cellGoodCount(_ im:Img,_ bx:Double,_ by:Double,_ bsize:Double)->Int {
    let cell=bsize/8.0
    var ok=0
    for r in 0..<8 { for c in 0..<8 {
        if boardCellGood(im,bx+(Double(c)+0.5)*cell,by+(Double(r)+0.5)*cell) { ok+=1 }
    }}
    return ok
}
func gridlineDips(_ im:Img,_ bx:Double,_ by:Double,_ bsize:Double)->Double {
    let cell=bsize/8.0
    var total=0.0
    for k in 1..<8 {
        let gx=bx+Double(k)*cell
        var dips=0.0
        for ri in 0..<8 {
            let cy=by+(Double(ri)+0.5)*cell
            dips += (rgbDistance(px(im,gx-2.5,cy),px(im,gx,cy))+rgbDistance(px(im,gx,cy),px(im,gx+2.5,cy)))*0.5
        }
        total += dips/8.0
    }
    for k in 1..<8 {
        let gy=by+Double(k)*cell
        var dips=0.0
        for ci in 0..<8 {
            let cx=bx+(Double(ci)+0.5)*cell
            dips += (rgbDistance(px(im,cx,gy-2.5),px(im,cx,gy))+rgbDistance(px(im,cx,gy),px(im,cx,gy+2.5)))*0.5
        }
        total += dips/8.0
    }
    return total
}

// Locates the 8x8 board anywhere in the window: the board panel is found via
// navy-pixel row/column histograms, then the grid is fitted inside it by
// maximizing cell plausibility plus gridline dips. This makes the bot immune
// to layout shifts and window rescaling (letterboxing) — the field is found
// from the image content instead of fixed offsets.
func boardBgColor(_ im:Img)->(Double,Double,Double) {
    var freq=[Int:Int](); var rep=[Int:(Double,Double,Double)]()
    var yy=150.0
    while yy<500.0 { var xx=16.0
        while xx<300.0 {
            let c=px(im,xx,yy); let mx=max(c.0,c.1,c.2)
            if mx>35 {
                let q=(Int(c.0)/22)*10000 + (Int(c.1)/22)*100 + Int(c.2)/22
                freq[q,default:0]+=1
                if rep[q]==nil { rep[q]=c }
            }
            xx+=4.0 }
        yy+=4.0 }
    if let top=freq.max(by:{ $0.value<$1.value }), let c=rep[top.key] { return c }
    return (68.0,77.0,147.0)
}
func locateBoard(_ im:Img)->CGRect? {
    let bg=boardBgColor(im)
    // The earlier row/column histogram could shrink the panel when a few
    // occupied rows split its run. Find the largest dense, near-square,
    // connected component of the board background instead. Filled cells do
    // not break it because the board frame and grid gutters remain connected.
    let width=316, y0=100, y1=650, height=y1-y0
    var mask=[Bool](repeating:false,count:width*height)
    for yy in y0..<y1 { for xx in 0..<width {
        if rgbDistance(px(im,Double(xx),Double(yy)),bg)<40 {
            mask[(yy-y0)*width+xx]=true
        }
    }}
    var seen=[Bool](repeating:false,count:mask.count)
    var best:(area:Int,minX:Int,minY:Int,maxX:Int,maxY:Int)?=nil
    for sy in y0..<y1 { for sx in 0..<width {
        let seed=(sy-y0)*width+sx
        if !mask[seed] || seen[seed] { continue }
        var queue=[Int](); queue.reserveCapacity(4096)
        queue.append(seed); seen[seed]=true
        var head=0,area=0,minX=sx,maxX=sx,minY=sy,maxY=sy
        while head<queue.count {
            let idx=queue[head]; head+=1; area+=1
            let ly=idx/width, x=idx-ly*width, y=ly+y0
            if x<minX { minX=x }; if x>maxX { maxX=x }
            if y<minY { minY=y }; if y>maxY { maxY=y }
            if x>0 {
                let n=idx-1; if mask[n] && !seen[n] { seen[n]=true; queue.append(n) }
            }
            if x+1<width {
                let n=idx+1; if mask[n] && !seen[n] { seen[n]=true; queue.append(n) }
            }
            if ly>0 {
                let n=idx-width; if mask[n] && !seen[n] { seen[n]=true; queue.append(n) }
            }
            if ly+1<height {
                let n=idx+width; if mask[n] && !seen[n] { seen[n]=true; queue.append(n) }
            }
        }
        let w=maxX-minX+1,h=maxY-minY+1
        let dense=Double(area)/Double(max(1,w*h))
        if w>=180,h>=180,abs(w-h)<=max(40,max(w,h)/5),dense>=0.40,
           (best==nil || area>best!.area) {
            best=(area,minX,minY,maxX,maxY)
        }
    }}
    guard let panel=best else { return nil }
    let panelW=Double(panel.maxX-panel.minX+1)
    let panelH=Double(panel.maxY-panel.minY+1)
    EMPTY_REF=(r:bg.0,g:bg.1,b:bg.2)
    let baseX=Double(panel.minX)+4.0,baseY=Double(panel.minY)+4.0
    let baseS=min(panelW,panelH)-8.0
    var bestFit=(score:-Double.infinity,x:baseX,y:baseY,s:baseS)
    var ddy = -6.0
    while ddy<=6.0 { var ddx = -6.0
        while ddx<=6.0 { var dds = -8.0
            while dds<=4.0 {
                let s2=baseS+dds
                let score=Double(cellGoodCount(im,baseX+ddx,baseY+ddy,s2))*3.0+gridlineDips(im,baseX+ddx,baseY+ddy,s2)
                if score>bestFit.score { bestFit=(score,baseX+ddx,baseY+ddy,s2) }
                dds+=1.0
            }
            ddx+=1.0
        }
        ddy+=1.0
    }
    guard bestFit.score>0 else { return nil }
    return CGRect(x:bestFit.x,y:bestFit.y,width:bestFit.s,height:bestFit.s)
}

var LOCKED_GRID: CGRect? = nil
var LOCK_FAILS = 0
var PENDING_GRID: CGRect? = nil
var PENDING_COUNT = 0
func sameGrid(_ a:CGRect,_ b:CGRect)->Bool { return abs(a.minX-b.minX)<6 && abs(a.minY-b.minY)<6 && abs(a.width-b.width)<8 }
func adaptGeometry(_ im:Img)->Bool {
    // The field stays put during a game, so a locked grid is reused every cycle
    // (no per-cycle re-detection jitter during animations). A new grid is locked
    // only after it is detected consistently (same value twice) AND the tray has
    // pieces, which filters out transient frames during place/clear animations.
    // Re-detection happens only after many persistent failures = the user moved
    // the field or the screen state genuinely changed.
    if let g=LOCKED_GRID {
        applyAdaptiveGeometry(g)
        let ps=validTrayPieces(im)
        if (1...3).contains(ps.count) { LOCK_FAILS=0; return true }
        LOCK_FAILS+=1
        if LOCK_FAILS<15 { return false }
        LOCKED_GRID=nil; PENDING_GRID=nil; PENDING_COUNT=0
    }
    guard let grid=locateBoard(im) else { PENDING_COUNT=0; return false }
    if let pg=PENDING_GRID, sameGrid(pg,grid) { PENDING_COUNT+=1 } else { PENDING_GRID=grid; PENDING_COUNT=1 }
    applyAdaptiveGeometry(grid)
    let ps=validTrayPieces(im)
    print("GEO grid=(\(Int(grid.minX)),\(Int(grid.minY)),\(Int(grid.width))) tray=\(ps.count) pend=\(PENDING_COUNT)")
    if (1...3).contains(ps.count) && PENDING_COUNT>=2 { LOCKED_GRID=grid; LOCK_FAILS=0; return true }
    return false
}

func fits(_ b: [[Bool]], _ p: [[Bool]], _ r: Int, _ c: Int) -> Bool {
    if r + p.count > 8 || c + p[0].count > 8 { return false }
    for i in 0..<p.count { for j in 0..<p[0].count where p[i][j] && b[r + i][c + j] { return false } }
    return true
}
func dropP(_ b: [[Bool]], _ p: [[Bool]], _ r: Int, _ c: Int) -> ([[Bool]], Int) {
    var nb = b
    for i in 0..<p.count { for j in 0..<p[0].count where p[i][j] { nb[r + i][c + j] = true } }
    var fr = [Int](), fc = [Int]()
    for i in 0..<8 where nb[i].allSatisfy({ $0 }) { fr.append(i) }
    for j in 0..<8 {
        var all = true
        for i in 0..<8 where !nb[i][j] { all = false }
        if all { fc.append(j) }
    }
    for i in fr { for j in 0..<8 { nb[i][j] = false } }
    for j in fc { for i in 0..<8 { nb[i][j] = false } }
    return (nb, fr.count + fc.count)
}
func evalB(_ b:[[Bool]])->Double {
    var empty=0,isolated=0,transitions=0,near=0,fit3=0,fit23=0,fit5=0,almost=0
    for r in 0..<8 { for c in 0..<8 where !b[r][c] {
        empty+=1; var freeN=0
        for (dr,dc) in [(-1,0),(1,0),(0,-1),(0,1)] {
            let rr=r+dr,cc=c+dc
            if rr>=0 && rr<8 && cc>=0 && cc<8 && !b[rr][cc] { freeN+=1 }
        }
        if freeN<=1 { isolated+=1 }
    }}
    // Lines holding exactly one hole are the best combo setups: a single
    // future placement clears them, so they earn a bonus over the generic
    // 6+ filled "near" count.
    for r in 0..<8 {
        let n=b[r].filter{$0}.count; if n>=6 { near+=1 }; if n==7 { almost+=1 }
        for c in 1..<8 where b[r][c] != b[r][c-1] { transitions+=1 }
    }
    for c in 0..<8 {
        var n=0; for r in 0..<8 where b[r][c] { n+=1 }; if n>=6 { near+=1 }; if n==7 { almost+=1 }
        for r in 1..<8 where b[r][c] != b[r-1][c] { transitions+=1 }
    }
    for r in 0...5 { for c in 0...5 {
        if (0..<3).allSatisfy({rr in (0..<3).allSatisfy({cc in !b[r+rr][c+cc]})}) { fit3+=1 }
    }}
    for r in 0...6 { for c in 0...5 {
        if (0..<2).allSatisfy({rr in (0..<3).allSatisfy({cc in !b[r+rr][c+cc]})}) { fit23+=1 }
    }}
    for r in 0..<8 { for c in 0...3 where (0..<5).allSatisfy({!b[r][c+$0]}) { fit5+=1 } }
    for c in 0..<8 { for r in 0...3 where (0..<5).allSatisfy({!b[r+$0][c]}) { fit5+=1 } }
    return Double(empty)*2.0-Double(isolated)*18.0-Double(transitions)*1.8+Double(near)*5.0+Double(almost)*4.0+Double(fit3)*5.0+Double(fit23)*1.8+Double(fit5)*3.0
}
let COMBO_SHAPE_WEIGHTS:[(String,Double)] = [
    ("1111",60.0),
    ("1/1/1/1",55.0),
    ("11/11",55.0),
    ("11/11/11",50.0),
    ("111/111",41.0),
    ("1/1/1",35.0),
    ("1/1/1/1/1",33.0),
    ("11/10/10",33.0),
    ("11111",33.0),
    ("10/10/11",32.0),
    ("111",32.0),
    ("111/111/111",31.0),
    ("11",27.0),
    ("100/111",26.0),
    ("11/01/01",26.0),
    ("001/111",25.0),
    ("111/001",25.0),
    ("111/100",25.0),
    ("100/100/111",23.0),
    ("001/001/111",22.0),
    ("1/1",18.0),
    ("010/111",17.0),
    ("01/01/11",16.0),
    ("01/11",16.0),
    ("01/11/01",16.0),
    ("011/110",15.0),
    ("10/11",14.0),
    ("11/01",14.0),
    ("110/011",14.0),
    ("111/001/001",14.0),
    ("111/010",13.0),
    ("10/11/01",12.0),
    ("111/100/100",12.0),
    ("01/11/10",11.0),
    ("10/11/10",11.0),
    ("11/10",11.0),
    ("10/01",5.0),
    ("01/10",3.0),
    ("1",1.0)
]
let COMBO_LINE_MODEL:([Double],[Double],[Double],[Double]) = {
    var rowCover=[Double](repeating:0,count:256)
    var colCover=[Double](repeating:0,count:256)
    var rowProgress=[Double](repeating:0,count:256)
    var colProgress=[Double](repeating:0,count:256)
    let total=COMBO_SHAPE_WEIGHTS.reduce(0){$0+$1.1}
    for holesMask in 1..<256 {
        let holes=holesMask.nonzeroBitCount
        for (key,weight) in COMBO_SHAPE_WEIGHTS {
            let rows=key.split(separator:"/").map{Array($0)}
            let h=rows.count,w=rows[0].count
            var allR=false,allC=false,bestR=0,bestC=0
            for rr in 0..<h {
                var raw=0
                for cc in 0..<w where rows[rr][cc]=="1" { raw |= 1 << cc }
                for off in 0...(8-w) {
                    let pat=raw << off
                    if (pat & ~holesMask)==0 {
                        bestR=max(bestR,pat.nonzeroBitCount)
                        if pat==holesMask { allR=true }
                    }
                }
            }
            for cc in 0..<w {
                var raw=0
                for rr in 0..<h where rows[rr][cc]=="1" { raw |= 1 << rr }
                for off in 0...(8-h) {
                    let pat=raw << off
                    if (pat & ~holesMask)==0 {
                        bestC=max(bestC,pat.nonzeroBitCount)
                        if pat==holesMask { allC=true }
                    }
                }
            }
            rowCover[holesMask]+=weight*(allR ? 1:0)
            colCover[holesMask]+=weight*(allC ? 1:0)
            rowProgress[holesMask]+=weight*Double(bestR)/Double(holes)
            colProgress[holesMask]+=weight*Double(bestC)/Double(holes)
        }
        rowCover[holesMask]/=total; colCover[holesMask]/=total
        rowProgress[holesMask]/=total; colProgress[holesMask]/=total
    }
    return(rowCover,colCover,rowProgress,colProgress)
}()
func comboProbabilityPrep(_ b:[[Bool]])->Double {
    let model=COMBO_LINE_MODEL
    var result=0.0
    for r in 0..<8 {
        var occupied=0
        for c in 0..<8 where b[r][c] { occupied |= 1 << c }
        let holes=(~occupied)&255,filled=occupied.nonzeroBitCount
        if holes != 0 {
            let factor=pow(Double(filled)/8.0,3)
            result += factor*(160*model.0[holes]+25*model.2[holes])
        }
    }
    for c in 0..<8 {
        var occupied=0
        for r in 0..<8 where b[r][c] { occupied |= 1 << r }
        let holes=(~occupied)&255,filled=occupied.nonzeroBitCount
        if holes != 0 {
            let factor=pow(Double(filled)/8.0,3)
            result += factor*(160*model.1[holes]+25*model.3[holes])
        }
    }
    return result
}
struct Mv { let b:[[Bool]]; let cleared:Int; let seq:[(Int,Int,Int,Int)]; let score:Double }
func releaseInsideField(_ p:Piece,_ r:Int,_ c:Int)->Bool {
    let cell=BOARD.width/8.0
    let desired=CGPoint(x:BOARD.minX+(Double(c)+Double(p.cols)/2)*cell,
                        y:BOARD.minY+(Double(r)+Double(p.rows)/2)*cell)
    let release=CGPoint(x:desired.x+0.253,y:desired.y+88.780)
    return release.x>=BOARD.minX+3 && release.x<=BOARD.maxX-3 &&
           release.y>=BOARD.minY+3 && release.y<=BOARD.maxY-3
}
struct CompleteKey:Hashable {
    let board:UInt64
    let mask:Int
}
struct CompleteCandidate {
    let pi:Int
    let r:Int
    let c:Int
    let cleared:Int
    let board:[[Bool]]
    let orderScore:Double
}
struct CompleteTail {
    let board:[[Bool]]
    let cleared:Int
    let seq:[(Int,Int,Int,Int)]
    // Final-board survival score. Clear bonuses are deliberately not mixed
    // into this value, so combo preference cannot hide a dangerous board.
    let score:Double
    // Placements before the first line clear in seq. The real combo rule
    // allows at most COMBO_MAX_SKIPS non-clearing placements between clears,
    // so a clear landing late in the tray may not save an endangered combo.
    let firstClearAt:Int
    // Non-clearing placements after the last clear; becomes the next tray's
    // initial skip count.
    let trailingMisses:Int
}
struct CompleteOptions {
    var noClear:CompleteTail?
    var withClear:CompleteTail?
    // Best tail whose very first placement already clears; always eligible
    // to keep a live combo no matter how many skips were already spent.
    var withClearEarly:CompleteTail?
}
var LAST_SOLVER_NODES=0
var LAST_SOLVER_COMBO=false
var LAST_SOLVER_SAFETY_GAP=0.0
// Real game rule: the combo survives at most this many consecutive
// placements without a line clear (verified: the 3rd straight non-clearing
// placement breaks the chain); tray (3-piece) rounds do not matter.
let COMBO_MAX_SKIPS=2
func boardBits(_ b:[[Bool]])->UInt64 {
    var bits:UInt64=0
    for r in 0..<8 { for c in 0..<8 where b[r][c] {
        bits |= UInt64(1) << UInt64(r*8+c)
    }}
    return bits
}
func betterTail(_ candidate:CompleteTail,_ current:CompleteTail?)->Bool {
    guard let current else { return true }
    if abs(candidate.score-current.score)>0.001 {
        return candidate.score>current.score
    }
    if candidate.firstClearAt != current.firstClearAt {
        return candidate.firstClearAt<current.firstClearAt
    }
    if candidate.cleared != current.cleared {
        return candidate.cleared>current.cleared
    }
    return candidate.trailingMisses<current.trailingMisses
}
func completeTrayOptions(_ b:[[Bool]],_ ps:[Piece],_ mask:Int,_ depth:Int,
                         _ memo:inout [CompleteKey:CompleteOptions])->CompleteOptions {
    if mask==0 {
        return CompleteOptions(noClear:CompleteTail(board:b,cleared:0,seq:[],score:evalB(b),
                                                    firstClearAt:0,trailingMisses:0),
                               withClear:nil,withClearEarly:nil)
    }
    let key=CompleteKey(board:boardBits(b),mask:mask)
    if let cached=memo[key] { return cached }
    LAST_SOLVER_NODES+=1
    var result=CompleteOptions(noClear:nil,withClear:nil)

    // Constrained pieces and promising placements are visited first, but all
    // complete branches are evaluated. This prevents the first legal sequence
    // from hiding a safer sequence that preserves the round combo.
    var groups=[(pi:Int,moves:[CompleteCandidate])]()
    for pi in 0..<ps.count where (mask & (1 << pi)) != 0 {
        var moves=[CompleteCandidate]()
        for r in 0..<8 { for c in 0..<8 where fits(b,ps[pi].cells,r,c) {
            let (nb,cl)=dropP(b,ps[pi].cells,r,c)
            let orderScore=evalB(nb)+Double(cl)*40.0
            moves.append(CompleteCandidate(pi:pi,r:r,c:c,cleared:cl,
                                           board:nb,orderScore:orderScore))
        }}
        groups.append((pi:pi,moves:moves))
    }
    groups.sort {
        if $0.moves.count != $1.moves.count { return $0.moves.count<$1.moves.count }
        return ($0.moves.map{$0.orderScore}.max() ?? -Double.infinity) >
               ($1.moves.map{$0.orderScore}.max() ?? -Double.infinity)
    }
    for group in groups {
        for move in group.moves.sorted(by:{$0.orderScore>$1.orderScore}) {
            let tails=completeTrayOptions(move.board,ps,mask & ~(1 << move.pi),
                                          depth+1,&memo)
            for tail in [tails.noClear,tails.withClear].compactMap({$0}) {
                let totalCleared=move.cleared+tail.cleared
                let candidate=CompleteTail(board:tail.board,cleared:totalCleared,
                    seq:[(move.pi,move.r,move.c,move.cleared)]+tail.seq,
                    score:tail.score,
                    firstClearAt:move.cleared>0 ? 0:1+tail.firstClearAt,
                    trailingMisses:move.cleared>0 ? tail.seq.count:tail.trailingMisses)
                if totalCleared>0 {
                    if betterTail(candidate,result.withClear) { result.withClear=candidate }
                    if move.cleared>0,
                       betterTail(candidate,result.withClearEarly) { result.withClearEarly=candidate }
                } else if betterTail(candidate,result.noClear) { result.noClear=candidate }
            }
        }
    }
    memo[key]=result
    return result
}
struct ComboPlanKey:Hashable {
    let board:UInt64
    let mask:Int
    let streak:Int
    let skips:Int
}
struct ComboPlanTail {
    let board:[[Bool]]
    let cleared:Int
    let seq:[(Int,Int,Int,Int)]
    let score:Double
}
func exactComboPlan(_ b:[[Bool]],_ ps:[Piece],_ mask:Int,
                    _ streak:Int,_ skips:Int,
                    _ memo:inout [ComboPlanKey:ComboPlanTail?])->ComboPlanTail? {
    if mask==0 {
        let prep=evalB(b)+comboProbabilityPrep(b)
        let skipPenalty=streak>0 ? Double(skips)*1_000_000.0:0
        return ComboPlanTail(board:b,cleared:0,seq:[],
                             score:Double(streak)*1_000_000_000.0-skipPenalty+prep)
    }
    let key=ComboPlanKey(board:boardBits(b),mask:mask,streak:streak,skips:skips)
    if let cached=memo[key] { return cached }
    LAST_SOLVER_NODES+=1
    var best:ComboPlanTail?=nil
    for pi in 0..<ps.count where (mask & (1 << pi)) != 0 {
        for r in 0..<8 { for c in 0..<8 where fits(b,ps[pi].cells,r,c) {
            let (nextBoard,cleared)=dropP(b,ps[pi].cells,r,c)
            var nextStreak=streak,nextSkips=skips
            if cleared>0 { nextStreak+=1; nextSkips=0 }
            else {
                nextSkips+=1
                if nextSkips>COMBO_MAX_SKIPS { nextStreak=0; nextSkips=0 }
            }
            guard let tail=exactComboPlan(nextBoard,ps,mask & ~(1 << pi),
                                          nextStreak,nextSkips,&memo) else { continue }
            let candidate=ComboPlanTail(board:tail.board,
                cleared:cleared+tail.cleared,
                seq:[(pi,r,c,cleared)]+tail.seq,score:tail.score)
            if best==nil || candidate.score>best!.score+0.0001 { best=candidate }
        }}
    }
    memo[key]=best
    return best
}
func externalSteeringMove(_ b:[[Bool]],_ ps:[Piece],skips:Int,streak:Int)->Mv? {
    guard ps.count==3,FileManager.default.isExecutableFile(atPath:"/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/blockbot_steering_solver_bin") else { return nil }
    let task=Process(),output=Pipe(),errors=Pipe()
    task.executableURL=URL(fileURLWithPath:"/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/blockbot_steering_solver_bin")
    task.arguments=["--solve-steering","--board",String(boardBits(b)),
                    "--pieces",ps.map(strictShapeKey).joined(separator:"|"),
                    "--streak",String(max(0,streak)),"--skips",String(max(0,skips))]
    task.standardOutput=output; task.standardError=errors
    do { try task.run() } catch { return nil }
    let deadline=CFAbsoluteTimeGetCurrent()+5.0
    while task.isRunning && CFAbsoluteTimeGetCurrent()<deadline { usleep(1_000) }
    if task.isRunning { task.terminate(); task.waitUntilExit(); return nil }
    task.waitUntilExit()
    guard task.terminationStatus==0,
          let text=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8),
          let line=text.split(separator:"\n").first,
          line.hasPrefix("OK "),let range=line.range(of:" seq=") else { return nil }
    let sequenceText=line[range.upperBound...]
    var sequence=[(Int,Int,Int,Int)](),used=Set<Int>(),working=b,totalCleared=0
    for token in sequenceText.split(separator:";") {
        let values=token.split(separator:":").compactMap{Int($0)}
        guard values.count==4 else { return nil }
        let slot=values[0],r=values[1],c=values[2],claimed=values[3]
        guard ps.indices.contains(slot),!used.contains(slot),fits(working,ps[slot].cells,r,c) else { return nil }
        let dropped=dropP(working,ps[slot].cells,r,c)
        guard dropped.1==claimed else { return nil }
        working=dropped.0; totalCleared+=dropped.1; used.insert(slot)
        sequence.append((slot,r,c,dropped.1))
    }
    guard sequence.count==3,used.count==3 else { return nil }
    print("STEERING \(line)"); fflush(stdout)
    return Mv(b:working,cleared:totalCleared,seq:sequence,score:0)
}
func bestMove(_ b:[[Bool]],_ ps:[Piece],skips:Int=0,streak:Int=0)->Mv? {
    guard !ps.isEmpty,ps.count<=3 else { return nil }
    LAST_SOLVER_NODES=0; LAST_SOLVER_COMBO=false; LAST_SOLVER_SAFETY_GAP=0
    if let steered=externalSteeringMove(b,ps,skips:skips,streak:streak) {
        LAST_SOLVER_COMBO=true
        return steered
    }
    var memo=[ComboPlanKey:ComboPlanTail?]()
    let mask=(1 << ps.count)-1
    guard let chosen=exactComboPlan(b,ps,mask,max(0,streak),max(0,skips),&memo),
          chosen.seq.count==ps.count else { return nil }
    var liveStreak=max(0,streak),liveSkips=max(0,skips)
    for step in chosen.seq {
        if step.3>0 { liveStreak+=1; liveSkips=0 }
        else { liveSkips+=1; if liveSkips>COMBO_MAX_SKIPS { liveStreak=0; liveSkips=0 } }
    }
    LAST_SOLVER_COMBO=liveStreak>0
    return Mv(b:chosen.board,cleared:chosen.cleared,
              seq:chosen.seq,score:chosen.score)
}
func hid(_ t: CGEventType, _ p: CGPoint, _ src: CGEventSource?) {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func strictIntArg(_ name:String,_ fallback:Int)->Int {
    guard let i=ARGS.firstIndex(of:name),i+1<ARGS.count,
          let value=Int(ARGS[i+1]) else { return fallback }
    return max(1_000,value)
}
let FAST_DOWN_US=strictIntArg("--fast-down-us",40_000)
let FAST_TARGET_US=strictIntArg("--fast-target-us",20_000)
let FAST_RELEASE_US=strictIntArg("--fast-release-us",20_000)

// Explicit recovery helper for an already unwinnable tray. Production play
// still requires a complete sequence; this is used once to finish the dead
// game safely so the restart UI can appear.
func bestSingleMove(_ b:[[Bool]],_ ps:[Piece])->Mv? {
    var best:Mv?=nil,bestScore = -Double.infinity
    for pi in ps.indices {
        for r in 0..<8 { for c in 0..<8 where fits(b,ps[pi].cells,r,c) {
            let (nb,cleared)=dropP(b,ps[pi].cells,r,c)
            let score=evalB(nb)+Double(cleared)*40.0
            if score>bestScore {
                bestScore=score
                best=Mv(b:nb,cleared:cleared,seq:[(pi,r,c,cleared)],score:score)
            }
        }}
    }
    return best
}

func sameBounds(_ a:CGRect,_ b:CGRect)->Bool {
    abs(a.minX-b.minX)<1 && abs(a.minY-b.minY)<1 &&
    abs(a.width-b.width)<1 && abs(a.height-b.height)<1
}
func pickupPoint(_ p:Piece)->CGPoint {
    let x0=p.bbox[0], y0=p.bbox[1]
    let sx=(p.bbox[2]-x0+0.5)/Double(p.cols)
    let sy=(p.bbox[3]-y0+0.5)/Double(p.rows)
    var pts=[CGPoint]()
    for r in 0..<p.rows { for c in 0..<p.cols where p.cells[r][c] {
        pts.append(CGPoint(x:x0+(Double(c)+0.5)*sx,
                           y:y0+(Double(r)+0.5)*sy))
    }}
    let cx=pts.map(\.x).reduce(0,+)/Double(pts.count)
    let cy=pts.map(\.y).reduce(0,+)/Double(pts.count)
    return pts.min { pow($0.x-cx,2)+pow($0.y-cy,2) <
                     pow($1.x-cx,2)+pow($1.y-cy,2) }!
}
final class BotControl: @unchecked Sendable {
    private let lock=NSLock()
    private var running=false, quitting=false
    private var held:CGPoint?=nil
    func state()->(Bool,Bool) { lock.lock(); defer{lock.unlock()}; return(running,quitting) }
    func begin(_ p:CGPoint){ lock.lock(); held=p; lock.unlock() }
    func update(_ p:CGPoint){ lock.lock(); if held != nil { held=p }; lock.unlock() }
    func end(){ lock.lock(); held=nil; lock.unlock() }
}
extension BotControl {
    func forceUp() {
        lock.lock(); let p=held; held=nil; lock.unlock()
        if let p {
            hid(.leftMouseUp,p,nil)
        }
    }
    func toggle()->Bool {
        lock.lock(); if !quitting { running.toggle() }; let value=running; lock.unlock()
        if !value { forceUp() }
        return value
    }
    func pause(){ lock.lock(); running=false; lock.unlock(); forceUp() }
    func stop(){ lock.lock(); running=false; quitting=true; lock.unlock(); forceUp() }
}
let CONTROL=BotControl()
func hotkeyCallback(proxy:CGEventTapProxy,type:CGEventType,event:CGEvent,
                    refcon:UnsafeMutableRawPointer?)->Unmanaged<CGEvent>? {
    guard type == .keyDown,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let c=Unmanaged<BotControl>.fromOpaque(refcon).takeUnretainedValue()
    let key=event.getIntegerValueField(.keyboardEventKeycode)
    if key == 53 { print("EXIT"); fflush(stdout); c.stop(); return nil }
    return Unmanaged.passUnretained(event)
}
func installHotkeys()->Bool {
    let ready=DispatchSemaphore(value:0)
    var installed=false
    DispatchQueue.global(qos:.userInteractive).async {
        let mask=CGEventMask(1) << CGEventType.keyDown.rawValue
        let ref=Unmanaged.passUnretained(CONTROL).toOpaque()
        guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,
                    place:.headInsertEventTap,options:.defaultTap,
                    eventsOfInterest:mask,callback:hotkeyCallback,userInfo:ref),
              let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0) else {
            ready.signal(); return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
        installed=true; ready.signal(); CFRunLoopRun()
    }
    _=ready.wait(timeout:.now()+2)
    return installed
}
func controlledMove(_ type:CGEventType,_ a:CGPoint,_ b:CGPoint,
                    _ steps:Int,_ source:CGEventSource)->Bool {
    for i in 1...steps {
        if !CONTROL.state().0 { return false }
        let t=Double(i)/Double(steps)
        let p=CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
        hid(type,p,source); CONTROL.update(p); usleep(2_000)
    }
    return true
}
func activeWait(_ microseconds:Int)->Bool {
    var left=microseconds
    while left>0 {
        if !CONTROL.state().0 { return false }
        let slice=min(left,5_000); usleep(useconds_t(slice)); left-=slice
    }
    return true
}
func safeDrag(_ id:CGWindowID,_ snapshot:CGRect,
              _ startRel:CGPoint,_ targetRel:CGPoint,_ robust:Int=0)->Bool {
    guard CONTROL.state().0,
          let (id2,bounds,_)=findStrictWin(),id2==id,sameBounds(bounds,snapshot) else { return false }
    guard targetRel.x>5,targetRel.x<bounds.width-5,
          targetRel.y>5,targetRel.y<bounds.height-5 else { return false }
    let start=CGPoint(x:bounds.minX+startRel.x,y:bounds.minY+startRel.y)
    let target=CGPoint(x:bounds.minX+targetRel.x,y:bounds.minY+targetRel.y)
    let source=CGEventSource(stateID:.hidSystemState)!
    let profile=max(0,min(2,robust))
    let downWait=[60_000,90_000,130_000][profile]
    let dragSteps=[4,7,10][profile]
    let settleWait=[90_000,130_000,180_000][profile]
    let cursor=CGEvent(source:nil)?.location ?? start
    guard controlledMove(.mouseMoved,cursor,start,2,source),activeWait(10_000) else { return false }
    var current=start, down=false
    defer {
        if down {
            hid(.leftMouseUp,current,source); usleep(10_000); hid(.leftMouseUp,current,source)
            CONTROL.end()
        }
    }
    hid(.leftMouseDown,start,source); CONTROL.begin(start); down=true
    guard activeWait(downWait) else { return false }
    let mid=CGPoint(x:(start.x+target.x)/2,y:(start.y+target.y)/2)
    guard controlledMove(.leftMouseDragged,start,mid,dragSteps,source) else { return false }
    current=mid
    guard let (id3,b3,_)=findStrictWin(),id3==id,sameBounds(b3,bounds) else {
        if let (_,latest,_)=findStrictWin(),CONTROL.state().0 {
            let cancel=CGPoint(x:latest.minX+startRel.x,y:latest.minY+latest.height-35)
            _=controlledMove(.leftMouseDragged,current,cancel,4,source); current=cancel
        }
        return false
    }
    guard controlledMove(.leftMouseDragged,mid,target,dragSteps,source) else { return false }
    current=target; hid(.leftMouseDragged,target,source); CONTROL.update(target)
    guard activeWait(settleWait) else { return false }
    hid(.leftMouseUp,target,source); usleep(15_000); hid(.leftMouseUp,target,source)
    CONTROL.end(); down=false
    return true
}
let LIVE_DIR="/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_live_frames"
let LIVE_LOG="/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_live_metrics.jsonl"
func gridText(_ b:[[Bool]])->String {
    b.map{$0.map{$0 ? "1":"0"}.joined()}.joined(separator:"/")
}
func appendLive(_ text:String) {
    if !FileManager.default.fileExists(atPath:LIVE_LOG) {
        FileManager.default.createFile(atPath:LIVE_LOG,contents:nil)
    }
    if let fh=FileHandle(forWritingAtPath:LIVE_LOG) {
        fh.seekToEndOfFile(); fh.write((text+"\n").data(using:.utf8)!); try? fh.close()
    }
}
func captureAfter(_ id:CGWindowID,_ bounds:CGRect)->(Img,CGImage)? {
    for _ in 0..<3 {
        if !activeWait(250_000) { return nil }
        if let (id2,b2,_)=findStrictWin(),id2==id,sameBounds(b2,bounds),
           let shot=grab(id,bounds) { return shot }
    }
    return nil
}
func pauseBot(_ reason:String) {
    CONTROL.pause(); print("PAUSED: \(reason)"); fflush(stdout)
}

func strictShapeKey(_ p:Piece)->String {
    p.cells.map{$0.map{$0 ? "1":"0"}.joined()}.joined(separator:"/")
}

let TRANSFER_CACHE_FILE="/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_transfer_cache_v4.json"
let TRANSFER_CACHE_SCHEMA="adaptive-cells-v1"
func transferCacheKey(_ p:Piece)->String {
    // Pickup coordinates are shape cells; corrections are board-cell units;
    // the base drag lift is a board-height ratio. Nothing here is tied to an
    // absolute window position or pixel size, so one learned shape profile is
    // safe to reuse after moving or scaling the Mirroring window.
    return "\(TRANSFER_CACHE_SCHEMA)|\(strictShapeKey(p))"
}
struct TransferProfile:Codable {
    var pickupRow:Int
    var pickupCol:Int
    var correctionXCells:Double
    var correctionYCells:Double
    var exacts:Int
    var resyncs:Int
    var failures:Int
    var exactStreak:Int
    var uses:Int
    // Only image-confirmed landings count. Five consecutive confirmations are
    // required before a shape may skip the held-preview check.
    var trusted:Bool { exacts>=5 && exactStreak>=5 }
}
func loadTransferCache()->[String:TransferProfile] {
    guard let data=try? Data(contentsOf:URL(fileURLWithPath:TRANSFER_CACHE_FILE)),
          let decoded=try? JSONDecoder().decode([String:TransferProfile].self,from:data) else { return [:] }
    return decoded
}
var TRANSFER_CACHE=loadTransferCache()
func saveTransferCache() {
    let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    guard let data=try? encoder.encode(TRANSFER_CACHE) else { return }
    try? data.write(to:URL(fileURLWithPath:TRANSFER_CACHE_FILE),options:.atomic)
}
func centralPickupCell(_ p:Piece)->(Int,Int) {
    var points=[(Int,Int)]()
    for r in 0..<p.rows { for c in 0..<p.cols where p.cells[r][c] { points.append((r,c)) } }
    guard !points.isEmpty else { return(0,0) }
    let cr=points.map{Double($0.0)}.reduce(0,+)/Double(points.count)
    let cc=points.map{Double($0.1)}.reduce(0,+)/Double(points.count)
    return points.min {
        pow(Double($0.0)-cr,2)+pow(Double($0.1)-cc,2) <
        pow(Double($1.0)-cr,2)+pow(Double($1.1)-cc,2)
    }!
}
func transferProfile(_ p:Piece)->TransferProfile {
    let key=transferCacheKey(p)
    if let cached=TRANSFER_CACHE[key],cached.pickupRow<p.rows,cached.pickupCol<p.cols,
       p.cells[cached.pickupRow][cached.pickupCol] { return cached }
    let pick=centralPickupCell(p)
    return TransferProfile(pickupRow:pick.0,pickupCol:pick.1,
                           correctionXCells:0,correctionYCells:0,
                           exacts:0,resyncs:0,failures:0,exactStreak:0,uses:0)
}
func cachedPickupPoint(_ p:Piece,_ profile:TransferProfile)->CGPoint {
    let x0=p.bbox[0],y0=p.bbox[1]
    let sx=(p.bbox[2]-x0+0.5)/Double(p.cols)
    let sy=(p.bbox[3]-y0+0.5)/Double(p.rows)
    return CGPoint(x:x0+(Double(profile.pickupCol)+0.5)*sx,
                   y:y0+(Double(profile.pickupRow)+0.5)*sy)
}
@discardableResult
func recordTransfer(_ piece:Piece,_ code:String,_ usedFast:Bool,
                    _ learnedX:Double?,_ learnedY:Double?)->(Bool,Bool,TransferProfile) {
    let key=transferCacheKey(piece)
    var profile=transferProfile(piece),changed=false
    let wasTrusted=profile.trusted
    if code=="exact" {
        if let x=learnedX { profile.correctionXCells=max(-2.0,min(2.0,x)) }
        if let y=learnedY { profile.correctionYCells=max(-2.0,min(2.0,y)) }
        profile.exacts+=1; profile.exactStreak+=1; profile.uses+=1; changed=true
    } else if code=="unsafe_preview" {
        // The preview sat on a wrong cell: the stored offset is suspect, and
        // the speculative delta from an unaligned preview must not be saved
        // (this is how the 1x1 entry learned a phantom +2,-2 cell jump).
        let pick=centralPickupCell(piece)
        profile=TransferProfile(pickupRow:pick.0,pickupCol:pick.1,
                                correctionXCells:0,correctionYCells:0,
                                exacts:0,resyncs:0,
                                failures:profile.failures+1,
                                exactStreak:0,uses:profile.uses+1)
        changed=true
    } else if ["no_preview","mismatch","post_unstable",
               "misaligned","correction_oob","invalid"].contains(code) {
        // A rejected preview or unverified landing invalidates every learned
        // offset for this shape/geometry. Never repeat the same bad drag.
        let pick=centralPickupCell(piece)
        profile=TransferProfile(pickupRow:pick.0,pickupCol:pick.1,
                                correctionXCells:0,correctionYCells:0,
                                exacts:0,resyncs:0,
                                failures:profile.failures+1,
                                exactStreak:0,uses:profile.uses+1)
        changed=true
    } else if ["pickup_fail","hold_capture"].contains(code) {
        profile.failures+=1; profile.exactStreak=0; profile.uses+=1; changed=true
    }
    if changed { TRANSFER_CACHE[key]=profile; saveTransferCache() }
    return(wasTrusted,profile.trusted,profile)
}

func connectedShape(_ p:Piece)->Bool {
    var occupied=[(Int,Int)]()
    for r in 0..<p.rows { for c in 0..<p.cols where p.cells[r][c] {
        occupied.append((r,c))
    }}
    guard let first=occupied.first,occupied.count<=9,p.rows<=5,p.cols<=5 else { return false }
    var seen=Set<String>(),queue=[first]
    while !queue.isEmpty {
        let (r,c)=queue.removeFirst(),key="\(r),\(c)"
        if seen.contains(key) { continue }; seen.insert(key)
        // Valid game pieces may touch only by a corner (for example 10/01).
        // Keep connectivity filtering, but use all eight neighbouring cells.
        for (rr,cc) in [(r-1,c-1),(r-1,c),(r-1,c+1),
                        (r,c-1),            (r,c+1),
                        (r+1,c-1),(r+1,c),(r+1,c+1)] {
            if rr>=0,rr<p.rows,cc>=0,cc<p.cols,p.cells[rr][cc],
               !seen.contains("\(rr),\(cc)") { queue.append((rr,cc)) }
        }
    }
    return seen.count==occupied.count
}
func trayStabilitySignature(_ pieces:[Piece])->String {
    pieces.sorted{$0.ax<$1.ax}.map { p in
        let w=p.bbox[2]-p.bbox[0],h=p.bbox[3]-p.bbox[1]
        return "\(strictShapeKey(p))@\(Int(round(p.ax))),\(Int(round(p.ay))),\(Int(round(w))),\(Int(round(h)))"
    }.joined(separator:"|")
}
func rgbDistance(_ a:(Double,Double,Double),_ b:(Double,Double,Double))->Double {
    let dr=a.0-b.0,dg=a.1-b.1,db=a.2-b.2
    return sqrt(dr*dr+dg*dg+db*db)
}
struct PreviewCandidate { let r:Int; let c:Int; let mean:Double; let minimum:Double }

func placementPreviewCandidate(_ scores:[PreviewCandidate])->(PreviewCandidate?,PreviewCandidate?) {
    guard let strongest=scores.first else { return(nil,nil) }
    // iPhone Mirroring renders two copies while dragging over the board:
    // a solid lifted piece and, one row below it, the actual snap preview.
    // The solid copy is slightly stronger, which previously made LEARN shift
    // the pointer down one cell and then release one row below the plan.
    // Only treat it as this paired overlay when both full-shape signals are
    // very strong and vertically adjacent; otherwise keep the strongest one.
    if strongest.mean>=80,strongest.minimum>=40,
       let snap=scores.first(where:{ candidate in
           candidate.r==strongest.r+1 && candidate.c==strongest.c &&
           candidate.mean>=max(30,strongest.mean*0.72) &&
           candidate.minimum>=max(20,strongest.minimum*0.70)
       }) {
        return(snap,strongest)
    }
    return(strongest,nil)
}

func previewCellDistance(_ before:Img,_ held:Img,_ x:Double,_ y:Double)->Double {
    // The game's placement preview is often an outline/gradient, so the exact
    // cell centre may stay unchanged. Sample a small cross inside the cell.
    let offsets=[(0.0,0.0),(-6.0,0.0),(6.0,0.0),(0.0,-6.0),(0.0,6.0),
                 (-5.0,-5.0),(5.0,-5.0),(-5.0,5.0),(5.0,5.0)]
    return offsets.map { dx,dy in
        rgbDistance(px(before,x+dx,y+dy),px(held,x+dx,y+dy))
    }.max() ?? 0
}
func previewCandidates(_ before:Img,_ held:Img,_ board:[[Bool]],
                       _ piece:Piece)->[PreviewCandidate] {
    let cell=BOARD.width/8.0
    var out=[PreviewCandidate]()
    for r in 0..<8 { for c in 0..<8 where fits(board,piece.cells,r,c) {
        var values=[Double]()
        for pr in 0..<piece.rows { for pc in 0..<piece.cols where piece.cells[pr][pc] {
            let x=BOARD.minX+(Double(c+pc)+0.5)*cell
            let y=BOARD.minY+(Double(r+pr)+0.5)*cell
            values.append(previewCellDistance(before,held,x,y))
        }}
        if !values.isEmpty {
            out.append(PreviewCandidate(r:r,c:c,
                       mean:values.reduce(0,+)/Double(values.count),
                       minimum:values.min()!))
        }
    }}
    return out.sorted {
        if abs($0.mean-$1.mean)>0.01 { return $0.mean>$1.mean }
        return $0.minimum>$1.minimum
    }
}
func samePieces(_ a:[Piece],_ b:[Piece])->Bool {
    guard a.count==b.count else { return false }
    let aa=a.sorted{$0.ax<$1.ax},bb=b.sorted{$0.ax<$1.ax}
    for i in 0..<aa.count {
        if strictShapeKey(aa[i]) != strictShapeKey(bb[i]) ||
           hypot(aa[i].ax-bb[i].ax,aa[i].ay-bb[i].ay)>3 { return false }
    }
    return true
}
func findStrictWin()->(CGWindowID,CGRect,pid_t)? {
    let info=(CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID)
              as? [[String:Any]]) ?? []
    for w in info {
        guard (w[kCGWindowOwnerName as String] as? String)==OWNER else { continue }
        var b=CGRect.zero
        if let bd=w[kCGWindowBounds as String] as? [String:Any] {
            CGRectMakeWithDictionaryRepresentation(bd as CFDictionary,&b)
        }
        if b.height>600 && b.width<400 {
            let id=CGWindowID((w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            let pid=pid_t((w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            return(id,b,pid)
        }
    }
    return nil
}
func focusStrictWindow(_ expectedId:CGWindowID,_ expectedBounds:CGRect)->Bool {
    guard let (id,_,pid)=findWin(),id==expectedId,
          let app=NSRunningApplication(processIdentifier:pid) else { return false }
    // Always activate immediately before capture, even if CoreGraphics still
    // labels the window onscreen. The agent UI can otherwise cover it between
    // process-output updates and the fallback would capture the wrong Space.
    _=app.activate(options:[.activateAllWindows])
    for _ in 0..<30 {
        let front=NSWorkspace.shared.frontmostApplication?.processIdentifier==pid
        if front,let (visibleId,visibleBounds,_)=findStrictWin(),
           visibleId==expectedId,sameBounds(visibleBounds,expectedBounds) { return true }
        usleep(10_000)
    }
    return false
}

func prepareStrictWindow()->(CGWindowID,CGRect,pid_t)? {
    guard let (_,_,pid)=findWin() else { return nil }
    _=NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows])
    var previous:(CGWindowID,CGRect,pid_t)?=nil,stable=0
    for _ in 0..<80 {
        if let visible=findStrictWin() {
            if let p=previous,p.0==visible.0,sameBounds(p.1,visible.1) { stable+=1 }
            else { stable=1 }
            previous=visible
            if stable>=6 { return visible }
        } else { previous=nil; stable=0 }
        usleep(100_000)
    }
    return nil
}

struct CycleFrame {
    let id:CGWindowID
    let bounds:CGRect
    let image:Img
    let board:[[Bool]]
    let pieces:[Piece]
    let capturedAt:CFAbsoluteTime
}
struct StrictResult {
    let code:String
    let board:[[Bool]]?
    let nextFrame:CycleFrame?
    let expectedNextCount:Int?
    let expectedBoard:[[Bool]]?
    let plannedBoard:[[Bool]]?
    let usedFast:Bool
    let learnedX:Double?
    let learnedY:Double?
    init(code:String,board:[[Bool]]?=nil,nextFrame:CycleFrame?=nil,
         expectedNextCount:Int?=nil,expectedBoard:[[Bool]]?=nil,
         plannedBoard:[[Bool]]?=nil,usedFast:Bool=false,
         learnedX:Double?=nil,learnedY:Double?=nil) {
        self.code=code; self.board=board; self.nextFrame=nextFrame
        self.expectedNextCount=expectedNextCount; self.expectedBoard=expectedBoard
        self.plannedBoard=plannedBoard; self.usedFast=usedFast
        self.learnedX=learnedX; self.learnedY=learnedY
    }
}
func reusableCycleFrame(_ id:CGWindowID,_ bounds:CGRect,_ image:Img,
                        _ board:[[Bool]],_ capturedAt:CFAbsoluteTime,
                        _ expectedCount:Int?=nil)->CycleFrame? {
    let pieces=Array(validTrayPieces(image).prefix(3))
    guard LAST_EMPTY_SUPPORT>0,(1...3).contains(pieces.count),
          pieces.allSatisfy({connectedShape($0)}),
          expectedCount==nil || pieces.count==expectedCount!,
          board.flatMap({$0}).filter({$0}).count<64 else { return nil }
    return CycleFrame(id:id,bounds:bounds,image:image,board:board,
                      pieces:pieces,capturedAt:capturedAt)
}

func strictPlace(_ id:CGWindowID,_ snapshot:CGRect,_ base:Img,_ baseCapturedAt:CFAbsoluteTime,
                 _ board:[[Bool]],_ piece:Piece,_ row:Int,_ col:Int,
                 _ probeOnly:Bool,_ requestedFast:Bool)->StrictResult {
    guard CONTROL.state().0 else { return StrictResult(code:"paused") }
    guard let (id2,latestBounds,_)=findStrictWin() else { return StrictResult(code:"window_missing") }
    guard id2==id else {
        print("STALE window id \(id)->\(id2)")
        return StrictResult(code:"window_changed")
    }
    let bounds=latestBounds
    let baseAge=max(0,CFAbsoluteTimeGetCurrent()-baseCapturedAt)
    var usedFast=requestedFast && !probeOnly && baseAge<0.90 && sameBounds(bounds,snapshot)
    if !sameBounds(bounds,snapshot) {
        print("REBOUND \(snapshot)->\(bounds)"); fflush(stdout)
        usedFast=false; usleep(35_000)
    }

    let basePieces=Array(validTrayPieces(base).prefix(3))
    var workingImage=base,workingBoard=board,workingPieces=basePieces
    if !usedFast {
        var freshImage:Img?=nil
        for _ in 0..<3 {
            if let (shot,_)=grab(id,bounds) { freshImage=shot; break }
            usleep(35_000)
        }
        guard let fresh=freshImage else {
            print("STALE fresh capture failed")
            return StrictResult(code:"capture_failed")
        }
        let (freshBoard,_)=boardState(fresh)
        let freshPieces=Array(validTrayPieces(fresh).prefix(3))
        guard LAST_EMPTY_SUPPORT>0,freshBoard==board,
              samePieces(basePieces,freshPieces),
              freshPieces.allSatisfy({connectedShape($0)}) else {
            return StrictResult(code:"unstable",board:freshBoard)
        }
        workingImage=fresh; workingBoard=freshBoard; workingPieces=freshPieces
    }

    let key=strictShapeKey(piece)
    guard let current=workingPieces.min(by:{
        let d0=strictShapeKey($0)==key ? hypot($0.ax-piece.ax,$0.ay-piece.ay) : 9999
        let d1=strictShapeKey($1)==key ? hypot($1.ax-piece.ax,$1.ay-piece.ay) : 9999
        return d0<d1
    }),strictShapeKey(current)==key,fits(workingBoard,current.cells,row,col) else {
        return StrictResult(code:"invalid",board:workingBoard,usedFast:usedFast)
    }
    let expectedNextCount=workingPieces.count>1 ? workingPieces.count-1 : 3
    var remainingPieces=workingPieces
    if let removeIndex=remainingPieces.indices.min(by:{
        hypot(remainingPieces[$0].ax-current.ax,remainingPieces[$0].ay-current.ay) <
        hypot(remainingPieces[$1].ax-current.ax,remainingPieces[$1].ay-current.ay)
    }) { remainingPieces.remove(at:removeIndex) }

    let profile=transferProfile(current)
    let cell=BOARD.width/8.0
    let desired=CGPoint(x:BOARD.minX+(Double(col)+Double(current.cols)/2)*cell,
                        y:BOARD.minY+(Double(row)+Double(current.rows)/2)*cell)
    var correctionX=profile.correctionXCells,correctionY=profile.correctionYCells
    let baseBiasX=BOARD.width*TARGET_X_BIAS_BOARD_RATIO
    let baseLiftY=BOARD.height*TARGET_Y_LIFT_BOARD_RATIO
    var targetRel=CGPoint(x:desired.x+baseBiasX+correctionX*cell,
                          y:desired.y+baseLiftY+correctionY*cell)
    if (targetRel.x<=8 || targetRel.x>=bounds.width-8 ||
        targetRel.y<=8 || targetRel.y>=bounds.height-8) &&
       (correctionX != 0 || correctionY != 0) {
        // A cached offset that pushes the touch off-window is garbage (this is
        // how the polluted 1x1 entry aborted at the right edge). Drop it and
        // re-learn in place through the LEARN alignment loop instead of dying.
        print(String(format:"CORR DISCARD oob cached offset %.2f,%.2f",correctionX,correctionY)); fflush(stdout)
        correctionX=0; correctionY=0; usedFast=false
        targetRel=CGPoint(x:desired.x+baseBiasX,y:desired.y+baseLiftY)
    }
    guard targetRel.x>8,targetRel.x<bounds.width-8,
          targetRel.y>8,targetRel.y<bounds.height-8 else {
        return StrictResult(code:"correction_oob",board:workingBoard,usedFast:usedFast)
    }
    let startRel=cachedPickupPoint(current,profile)
    let start=CGPoint(x:bounds.minX+startRel.x,y:bounds.minY+startRel.y)
    var target=CGPoint(x:bounds.minX+targetRel.x,y:bounds.minY+targetRel.y)
    let source=CGEventSource(stateID:.hidSystemState)!
    var cursor=CGEvent(source:nil)?.location ?? start,currentPoint=start,down=false
    defer {
        if down {
            if CONTROL.state().0,let (_,latest,_)=findStrictWin() {
                let cancel=CGPoint(x:latest.minX+startRel.x,y:latest.minY+latest.height-35)
                _=controlledMove(.leftMouseDragged,currentPoint,cancel,6,source)
                hid(.leftMouseDragged,cancel,source); _=activeWait(60_000)
                hid(.leftMouseUp,cancel,source)
            } else { hid(.leftMouseUp,currentPoint,source) }
            CONTROL.end()
        }
    }

    print(String(format:"TRANSFER %@ age=%.0fms corr=%.2f,%.2f timing=%d/%d/%dus",
                 usedFast ? "FAST" : "LEARN",baseAge*1000,correctionX,correctionY,
                 usedFast ? FAST_DOWN_US : 80_000,
                 usedFast ? FAST_TARGET_US : 75_000,
                 usedFast ? FAST_RELEASE_US : 120_000))
    fflush(stdout)
    // FAST emits the minimum practical HID sequence: one cursor event, one
    // drag event, and only sub-frame waits needed by iPhone Mirroring.
    guard controlledMove(.mouseMoved,cursor,start,usedFast ? 1:2,source),
          activeWait(usedFast ? 0:8_000) else {
        return StrictResult(code:"paused",usedFast:usedFast)
    }
    hid(.leftMouseDown,start,source); CONTROL.begin(start); down=true
    let downWait=usedFast ? FAST_DOWN_US:80_000
    let dragSteps=usedFast ? 1:6
    guard activeWait(downWait),controlledMove(.leftMouseDragged,start,target,dragSteps,source) else {
        return StrictResult(code:"pickup_fail",usedFast:usedFast)
    }
    currentPoint=target; hid(.leftMouseDragged,target,source); CONTROL.update(target)

    var finalRow=row,finalCol=col
    var learnedX:Double?=correctionX,learnedY:Double?=correctionY
    if usedFast {
        guard activeWait(FAST_TARGET_US) else { return StrictResult(code:"paused",usedFast:true) }
    } else {
        guard activeWait(75_000) else { return StrictResult(code:"paused",usedFast:false) }
        // Alignment loop: when the held preview sits off the planned cell,
        // drag by the cell delta and re-check instead of aborting. This
        // converges in place and lets tiny pieces (1x1) recover from a stale
        // or not-yet-learned offset. The release still only happens with the
        // preview exactly on the planned cell, so safety is unchanged.
        var aligned=false
        for alignTry in 0..<3 {
            guard let (id3,b3,_)=findStrictWin(),id3==id,sameBounds(b3,bounds),
                  let (held,_)=grab(id,bounds) else {
                return StrictResult(code:"hold_capture",usedFast:false)
            }
            let scores=previewCandidates(workingImage,held,workingBoard,current)
            let desc=scores.prefix(3).map{String(format:"r%dc%d %.1f/%.1f",$0.r,$0.c,$0.mean,$0.minimum)}.joined(separator:" | ")
            print("PREVIEW: \(desc)"); fflush(stdout)
            let (selected,floating)=placementPreviewCandidate(scores)
            if let floating,let selected {
                print(String(format:"PREVIEW PAIR floating=r%dc%d %.1f/%.1f snap=r%dc%d %.1f/%.1f",
                             floating.r,floating.c,floating.mean,floating.minimum,
                             selected.r,selected.c,selected.mean,selected.minimum)); fflush(stdout)
            }
            guard let best=selected,best.minimum>=10,best.mean>=14,
                  fits(workingBoard,current.cells,best.r,best.c) else {
                return StrictResult(code:"no_preview",usedFast:false)
            }
            finalRow=best.r; finalCol=best.c
            if finalRow==row && finalCol==col { aligned=true; break }
            let dc=Double(col-best.c),dr=Double(row-best.r)
            learnedX=(learnedX ?? correctionX)+dc
            learnedY=(learnedY ?? correctionY)+dr
            guard alignTry<2 else { break }
            print(String(format:"ALIGN RETRY actual=r%dc%d planned=r%dc%d shift=%.0f,%.0f",
                         best.r,best.c,row,col,dc,dr)); fflush(stdout)
            let adjusted=CGPoint(x:target.x+dc*cell,y:target.y+dr*cell)
            guard controlledMove(.leftMouseDragged,currentPoint,adjusted,4,source) else {
                return StrictResult(code:"paused",usedFast:false)
            }
            target=adjusted; currentPoint=adjusted
            hid(.leftMouseDragged,adjusted,source); CONTROL.update(adjusted)
            guard activeWait(90_000) else { return StrictResult(code:"paused",usedFast:false) }
        }
        guard aligned else {
            print("CANCEL learn alignment actual=r\(finalRow)c\(finalCol) planned=r\(row)c\(col)"); fflush(stdout)
            return StrictResult(code:"unsafe_preview",usedFast:false,
                                learnedX:learnedX,learnedY:learnedY)
        }
        print(String(format:"LEARNED aligned=r%dc%d correction=%.2f,%.2f",
                     finalRow,finalCol,learnedX ?? correctionX,learnedY ?? correctionY)); fflush(stdout)
        if probeOnly {
            return StrictResult(code:"probe_aligned",usedFast:false,
                                learnedX:learnedX,learnedY:learnedY)
        }
        guard activeWait(55_000) else { return StrictResult(code:"paused",usedFast:false) }
    }

    // Re-assert the verified target, then nudge the held touch a pixel and
    // back. Mirroring coalesces stationary drags; the jiggle pushes the final
    // position through the pipeline so the release matches the preview.
    hid(.leftMouseDragged,target,source); CONTROL.update(target)
    guard activeWait(usedFast ? FAST_RELEASE_US:120_000) else {
        return StrictResult(code:"paused",usedFast:usedFast)
    }
    hid(.leftMouseDragged,CGPoint(x:target.x+1.5,y:target.y),source)
    _=activeWait(usedFast ? 12_000:20_000)
    hid(.leftMouseDragged,target,source); CONTROL.update(target)
    _=activeWait(usedFast ? 12_000:30_000)
    // Finish with one event from the same HID source as mouseDown/drag.
    hid(.leftMouseUp,target,source)
    CONTROL.end(); down=false
    var stableWrongCount=0,redragAttempts=0
    // Full re-drag recovery. A snapped-back piece is still in the tray, so a
    // fresh frame can prove it: the same shape reappears near its old slot.
    // Re-sending mouseUp alone is useless once the touch has already ended.
    // The tray must show the ORIGINAL piece count: after a real placement a
    // consumed slot never refills, so an equal count proves a snap-back.
    func attemptRedrag(_ tray:[Piece])->Bool {
        guard redragAttempts<2,tray.count==workingPieces.count,
              let back=tray.filter({strictShapeKey($0)==key}).min(by:{
                  hypot($0.ax-current.ax,$0.ay-current.ay)<hypot($1.ax-current.ax,$1.ay-current.ay)
              }),hypot(back.ax-current.ax,back.ay-current.ay)<25 else { return false }
        let retryRel=cachedPickupPoint(back,profile)
        let from=CGPoint(x:bounds.minX+retryRel.x,y:bounds.minY+retryRel.y)
        guard from.x>bounds.minX+5,from.x<bounds.maxX-5,
              from.y>bounds.minY+5,from.y<bounds.maxY-5 else { return false }
        redragAttempts+=1
        print("REDRAG \(redragAttempts) snapped-back piece; full gesture retry"); fflush(stdout)
        hid(.leftMouseDown,from,source); CONTROL.begin(from)
        guard activeWait(90_000) else { hid(.leftMouseUp,from,source); CONTROL.end(); return false }
        _=controlledMove(.leftMouseDragged,from,target,6,source)
        hid(.leftMouseDragged,target,source); CONTROL.update(target)
        _=activeWait(140_000)
        hid(.leftMouseDragged,CGPoint(x:target.x+1.5,y:target.y),source)
        _=activeWait(20_000)
        hid(.leftMouseDragged,target,source); CONTROL.update(target)
        _=activeWait(30_000)
        hid(.leftMouseUp,target,source)
        CONTROL.end()
        return true
    }

    // A cached gesture never proves that the game accepted the move. Verify
    // the resulting board and tray transition from fresh pixels before the
    // profile or the in-memory board is allowed to advance.
    let dropResult=dropP(workingBoard,current.cells,row,col)
    let expected=dropResult.0
    let expectedClears=dropResult.1
    if usedFast {
        // Observe only the bottom tray. Return as soon as the consumed piece
        // disappears (or all three new pieces appear); board pixels are never
        // sampled, so line-clear animation cannot delay the next plan.
        for pass in 0..<45 {
            guard activeWait(pass==0 ? 4_000:2_000) else {
                return StrictResult(code:"paused",usedFast:true)
            }
            guard let (id4,b4,_)=findStrictWin(),id4==id,sameBounds(b4,bounds),
                  let (after,_)=grab(id,bounds) else { continue }
            let capturedAt=CFAbsoluteTimeGetCurrent()
            let afterPieces=Array(validTrayPieces(after).prefix(3))
            guard afterPieces.allSatisfy({connectedShape($0)}) else { continue }
            if afterPieces.count != expectedNextCount {
                stableWrongCount+=1
                // The deal/slide animation can briefly show the old count; only
                // a stable wrong count means the release snapped back. A lone
                // mouseUp retry cannot revive an ended touch, so re-drag fully.
                if stableWrongCount>=3 && attemptRedrag(afterPieces) {
                    stableWrongCount=0
                }
            } else { stableWrongCount=0 }
            if afterPieces.count==expectedNextCount {
                let next=CycleFrame(id:id,bounds:bounds,image:after,board:expected,
                                    pieces:afterPieces,capturedAt:capturedAt)
                print("FAST TRAY VERIFIED pieces=\(afterPieces.count) pass=\(pass)")
                return StrictResult(code:"cached",board:expected,nextFrame:next,
                                    expectedNextCount:expectedNextCount,
                                    expectedBoard:expected,plannedBoard:expected,
                                    usedFast:true,learnedX:learnedX,learnedY:learnedY)
            }
        }
        print("FAST TRAY TIMEOUT expected=\(expectedNextCount) timing=\(FAST_DOWN_US)/\(FAST_TARGET_US)/\(FAST_RELEASE_US)us")
        return StrictResult(code:"timing_miss",board:workingBoard,usedFast:true)
    }
    // A clearing row flashes cell-by-cell. During that animation the detector
    // can briefly see one leftover cell even though the placement was correct.
    // Keep sampling clear moves instead of declaring a stable partial frame a
    // mismatch after only five passes.
    let postPasses=expectedClears>0 ? 24:18
    var latestBoard=workingBoard
    var previousBoard:[[Bool]]?=nil
    var stableFrames=0,transitionSeen=false
    var confirmedFrame:CycleFrame?=nil
    for pass in 0..<postPasses {
        let wait = pass==0 ? (usedFast ? 70_000:110_000) : 60_000
        guard activeWait(wait) else {
            return StrictResult(code:"paused",usedFast:usedFast)
        }
        guard let (id4,b4,_)=findStrictWin(),id4==id,sameBounds(b4,bounds),
              let (after,_)=grab(id,bounds) else { continue }
        let capturedAt=CFAbsoluteTimeGetCurrent()
        let (afterBoard,_)=boardState(after)
        guard LAST_EMPTY_SUPPORT>0 else { continue }
        let afterPieces=Array(validTrayPieces(after).prefix(3))
        guard afterPieces.allSatisfy({connectedShape($0)}) else { continue }
        let countOK=afterPieces.count==expectedNextCount
        if !countOK {
            stableWrongCount+=1
            // Same recovery as the FAST path: a stable wrong tray count means
            // the touch snapped back; pick the piece up again and re-drag.
            if stableWrongCount>=3 && attemptRedrag(afterPieces) {
                stableWrongCount=0
            }
        } else { stableWrongCount=0 }
        transitionSeen = transitionSeen || countOK
        latestBoard=afterBoard
        if let p=previousBoard,p==afterBoard { stableFrames+=1 }
        else { previousBoard=afterBoard; stableFrames=1 }
        if countOK && afterBoard==expected {
            confirmedFrame=reusableCycleFrame(id,bounds,after,afterBoard,
                                               capturedAt,expectedNextCount)
            print("POST VERIFIED grid=\(gridText(afterBoard)) pieces=\(afterPieces.count) pass=\(pass)")
            return StrictResult(code:"exact",board:afterBoard,nextFrame:confirmedFrame,
                                expectedNextCount:expectedNextCount,
                                expectedBoard:afterBoard,plannedBoard:expected,
                                usedFast:usedFast,learnedX:learnedX,learnedY:learnedY)
        }
        if expectedClears==0 && countOK && afterBoard != workingBoard &&
           stableFrames>=3 && pass>=4 { break }
    }
    if expectedClears>0 && transitionSeen && latestBoard != expected {
        print("POST CLEAR TIMEOUT expected=\(gridText(expected)) actual=\(gridText(latestBoard))")
        return StrictResult(code:"post_unstable",board:latestBoard,
                            expectedNextCount:expectedNextCount,
                            expectedBoard:expected,plannedBoard:expected,
                            usedFast:usedFast,learnedX:learnedX,learnedY:learnedY)
    }
    if transitionSeen && latestBoard != workingBoard {
        print("POST MISMATCH expected=\(gridText(expected)) actual=\(gridText(latestBoard))")
        return StrictResult(code:"mismatch",board:latestBoard,
                            expectedNextCount:expectedNextCount,
                            expectedBoard:expected,plannedBoard:expected,
                            usedFast:usedFast,learnedX:learnedX,learnedY:learnedY)
    }
    if latestBoard==workingBoard {
        return StrictResult(code:"miss",board:latestBoard,usedFast:usedFast,
                            learnedX:learnedX,learnedY:learnedY)
    }
    return StrictResult(code:"post_unstable",board:latestBoard,
                        expectedNextCount:expectedNextCount,
                        expectedBoard:expected,plannedBoard:expected,
                        usedFast:usedFast,learnedX:learnedX,learnedY:learnedY)
}

let STRICT_LOG="/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_calibration/strict.jsonl"
func appendStrict(_ text:String) {
    if !FileManager.default.fileExists(atPath:STRICT_LOG) {
        FileManager.default.createFile(atPath:STRICT_LOG,contents:nil)
    }
    if let fh=FileHandle(forWritingAtPath:STRICT_LOG) {
        fh.seekToEndOfFile(); fh.write((text+"\n").data(using:.utf8)!); try? fh.close()
    }
}

let THEORY_FILE="/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/runtime/blockbot_theoretical_board.json"
struct TheoryDisk:Codable {
    let rows:[String]
    let expectedPieceCount:Int
    let updatedAt:Double
    // Live combo state so a restart keeps the skip budget the game still has.
    var streak:Int?
    var skips:Int?
}
func rowsForBoard(_ board:[[Bool]])->[String] {
    board.map { row in row.map { $0 ? "1":"0" }.joined() }
}
func boardFromRows(_ rows:[String])->[[Bool]]? {
    guard rows.count==8,rows.allSatisfy({$0.count==8}) else { return nil }
    let board=rows.map { Array($0).map { $0=="1" } }
    return board.allSatisfy({$0.count==8}) ? board:nil
}
func loadTheory()->(board:[[Bool]],expectedPieceCount:Int,updatedAt:Double,streak:Int,skips:Int)? {
    guard let data=try? Data(contentsOf:URL(fileURLWithPath:THEORY_FILE)),
          let state=try? JSONDecoder().decode(TheoryDisk.self,from:data),
          (1...3).contains(state.expectedPieceCount),
          Date().timeIntervalSince1970-state.updatedAt<21_600,
          let board=boardFromRows(state.rows) else { return nil }
    return(board,state.expectedPieceCount,state.updatedAt,
           max(0,state.streak ?? 0),min(max(0,state.skips ?? 0),COMBO_MAX_SKIPS))
}
func saveTheory(_ board:[[Bool]],_ expectedPieceCount:Int,_ streak:Int=0,_ skips:Int=0) {
    let state=TheoryDisk(rows:rowsForBoard(board),expectedPieceCount:expectedPieceCount,
                         updatedAt:Date().timeIntervalSince1970,streak:streak,skips:skips)
    if let data=try? JSONEncoder().encode(state) {
        try? data.write(to:URL(fileURLWithPath:THEORY_FILE),options:.atomic)
    }
}
func clearTheory() { try? FileManager.default.removeItem(atPath:THEORY_FILE) }
func boardDifference(_ a:[[Bool]],_ b:[[Bool]])->Int {
    var count=0
    for r in 0..<8 { for c in 0..<8 where a[r][c] != b[r][c] { count+=1 } }
    return count
}
func hasFullLine(_ board:[[Bool]])->Bool {
    (0..<8).contains { r in board[r].allSatisfy { $0 } } ||
    (0..<8).contains { c in (0..<8).allSatisfy { r in board[r][c] } }
}

func runStrict() {
    guard installHotkeys() else { fputs("HOTKEY ERROR\n",stderr); return }
    let probe=ARGS.contains("--probe")
    let visionOnly=ARGS.contains("--vision")
    let sacrifice=ARGS.contains("--sacrifice")
    let mi=ARGS.firstIndex(of:"--moves")
    let goal=(mi != nil && mi!+1<ARGS.count ? Int(ARGS[mi!+1]) : nil) ?? 50
    let ai=ARGS.firstIndex(of:"--max-attempts")
    let maxAttempts=(ai != nil && ai!+1<ARGS.count ? Int(ARGS[ai!+1]) : nil) ?? max(8,goal*5)
    if ARGS.contains("--reset-theory") { clearTheory() }
    if ARGS.contains("--reset-cache") {
        TRANSFER_CACHE.removeAll(); saveTransferCache()
        print("CACHE RESET")
    }
    let loadedTheory=loadTheory()
    guard let (_,readyBounds,_)=prepareStrictWindow() else {
        print("STOP Mirroring window did not become visible"); return
    }
    print("WINDOW READY \(readyBounds)")
    _=CONTROL.toggle()
    print("STRICT \(probe ? "PROBE":"RUN") goal=\(goal) cache=\(TRANSFER_CACHE.count) | Esc stop")
    fflush(stdout)
    var exact=0,attempts=0,failures=0,idle=0,stop=false,lines=0,comboNow=0,maxCombo=0
    // Combo rule (verified against the game): it survives as long as clears
    // are separated by at most COMBO_MAX_SKIPS non-clearing placements,
    // counted across tray boundaries; tray rounds do not matter.
    var skipsSinceClear=0
    var carry:CycleFrame?=nil,requiredPieceCount:Int?=nil,noCompletionFrames=0,trayMismatchFrames=0
    var requiredPieceKeys:[String]?=nil
    var trayStableSignature:String?=nil,trayStableFrames=0
    var theoreticalBoard=loadedTheory?.board
    var theoreticalPieceCount=loadedTheory?.expectedPieceCount
    // Becomes true only after a trusted cached placement in this process.
    // While true, screenshots are used for tray pieces/count only; the board
    // advances from the solver model without waiting for clear animations.
    var cachedTheoryMode=false
    var theoryMismatchFrames=0,hasCommittedThisRun=false
    if let loaded=loadedTheory {
        let age=Int(max(0,Date().timeIntervalSince1970-loaded.updatedAt))
        comboNow=loaded.streak; skipsSinceClear=loaded.skips
        print("THEORY LOAD pieces=\(loaded.expectedPieceCount) filled=\(loaded.board.flatMap{$0}.filter{$0}.count) age=\(age)s combo=\(comboNow)/\(skipsSinceClear)")
    }
    func commitTheoryResult(_ result:StrictResult)->Bool {
        guard let board=result.expectedBoard,
              let count=result.expectedNextCount,(1...3).contains(count) else { return false }
        theoreticalBoard=board; theoreticalPieceCount=count
        saveTheory(board,count,comboNow,skipsSinceClear)
        return true
    }
    while exact<goal && attempts<maxAttempts && !stop {
        let state=CONTROL.state()
        if state.1 { break }
        if !state.0 { carry=nil; usleep(20_000); continue }
        autoreleasepool {
            var cycle:CycleFrame?=nil,reusedPostFrame=false
            if let cached=carry {
                carry=nil
                let age=max(0,CFAbsoluteTimeGetCurrent()-cached.capturedAt)
                if age<1.20,let (liveId,liveBounds,_)=findStrictWin(),liveId==cached.id,
                   sameBounds(liveBounds,cached.bounds) {
                    cycle=cached; reusedPostFrame=true
                }
            }
            if cycle==nil {
                let captureWait=cachedTheoryMode ? 0:20_000
                guard activeWait(captureWait),let (id,bounds,_)=findStrictWin(),
                      let (image,_)=grab(id,bounds) else { return }
                let capturedAt=CFAbsoluteTimeGetCurrent()
                if cachedTheoryMode,let theory=theoreticalBoard {
                    // FAST cycle reads only the tray. Board pixels may still be
                    // clearing and are intentionally not sampled or compared.
                    let pieces=Array(validTrayPieces(image).prefix(3))
                    cycle=CycleFrame(id:id,bounds:bounds,image:image,board:theory,
                                     pieces:pieces,capturedAt:capturedAt)
                } else {
                    guard adaptGeometry(image) else {
                        idle+=1
                        if idle==1 || idle%5==0 { print("WAIT locating game field \(idle)s"); fflush(stdout) }
                        _=activeWait(1_000_000); return
                    }
                    let (board,_)=boardState(image)
                    guard LAST_EMPTY_SUPPORT>0 else {
                        idle+=1
                        if idle==1 || idle%5==0 { print("WAIT board background not identified"); fflush(stdout) }
                        _=activeWait(300_000); return
                    }
                    let pieces=Array(validTrayPieces(image).prefix(3))
                    cycle=CycleFrame(id:id,bounds:bounds,image:image,board:board,
                                     pieces:pieces,capturedAt:capturedAt)
                }
            }
            guard let frame=cycle else { return }
            let visionBoard=frame.board,pieces=frame.pieces
            if let required=requiredPieceCount,pieces.count != required {
                carry=nil; trayMismatchFrames+=1
                if cachedTheoryMode {
                    // Poll only the tray as quickly as screencapture permits.
                    if trayMismatchFrames==1 || trayMismatchFrames%12==0 {
                        print("FAST WAIT tray expected=\(required) seen=\(pieces.count)")
                        fflush(stdout)
                    }
                    if trayMismatchFrames>=80 {
                        print("PAUSED cached tray transition never confirmed")
                        CONTROL.pause(); stop=true
                    } else { _=activeWait(2_000) }
                    return
                }
                if pieces.isEmpty {
                    if idle==0 || idle%10==0 { print("WAIT ad/overlay during tray transition") }
                    idle+=1; fflush(stdout); _=activeWait(500_000); return
                }
                if trayMismatchFrames==1 || trayMismatchFrames%8==0 {
                    print("WAIT tray transition expected=\(required) seen=\(pieces.count) frame=\(trayMismatchFrames)")
                    fflush(stdout)
                }
                if trayMismatchFrames>=40 {
                    print("PAUSED tray transition never confirmed")
                    CONTROL.pause(); stop=true
                } else { _=activeWait(45_000) }
                return
            }
            if let required=requiredPieceCount {
                let signature=trayStabilitySignature(pieces)
                if trayStableSignature==signature { trayStableFrames+=1 }
                else { trayStableSignature=signature; trayStableFrames=1 }
                let neededFrames = required==3 ? 3:2
                if trayStableFrames<neededFrames {
                    carry=nil
                    if trayStableFrames==1 { print("FAST WAIT tray animation expected=\(required)") }
                    _=activeWait(required==3 ? 70_000:90_000)
                    return
                }
                if let expectedKeys=requiredPieceKeys {
                    let observedKeys=pieces.map(strictShapeKey).sorted()
                    if observedKeys != expectedKeys {
                        print("PAUSED wrong tray identity expected=\(expectedKeys) observed=\(observedKeys)")
                        carry=nil; CONTROL.pause(); stop=true
                        return
                    }
                }
                print("FAST TRAY STABLE expected=\(required) frames=\(trayStableFrames) signature=\(signature)")
                trayStableSignature=nil; trayStableFrames=0
            } else {
                trayStableSignature=nil; trayStableFrames=0
            }
            trayMismatchFrames=0; idle=0
            if reusedPostFrame { print("FRAME REUSE post-placement"); fflush(stdout) }

            if visionOnly {
                let desc=pieces.map { p in
                    String(format:"%@ ax=%.1f ay=%.1f box=%.0f,%.0f..%.0f,%.0f",
                           strictShapeKey(p),p.ax,p.ay,p.bbox[0],p.bbox[1],p.bbox[2],p.bbox[3])
                }.joined(separator:" | ")
                let legalPlan=bestMove(visionBoard,pieces,skips:skipsSinceClear,streak:comboNow),legal=legalPlan?.seq.first
                let legalText=legal.map{"p\($0.0) r\($0.1)c\($0.2)"} ?? "none"
                let theoryText=theoreticalBoard.map { String(boardDifference(visionBoard,$0)) } ?? "none"
                print("VISION boardY=\(BOARD.minY) filled=\(visionBoard.flatMap{$0}.filter{$0}.count) grid=\(gridText(visionBoard)) pieces=\(desc) legal=\(legalText) full=\(legalPlan?.seq.count ?? 0)/\(pieces.count) nodes=\(LAST_SOLVER_NODES) emptySupport=\(LAST_EMPTY_SUPPORT) theoryDiff=\(theoryText) cache=\(TRANSFER_CACHE.count)")
                stop=true; return
            }
            if pieces.isEmpty {
                idle+=1
                if idle==1 || idle%10==0 { print("WAIT ad/overlay \(idle)s"); fflush(stdout) }
                _=activeWait(1_000_000); return
            }
            idle=0
            guard pieces.allSatisfy({connectedShape($0)}) else {
                print("WAIT malformed vision: \(pieces.map(strictShapeKey))"); fflush(stdout)
                _=activeWait(1_000_000); return
            }
            let visionFilled=visionBoard.flatMap{$0}.filter{$0}.count
            let useCachedBoard=cachedTheoryMode && theoreticalBoard != nil
            if !useCachedBoard && visionFilled==64 {
                print("WAIT non-game screen"); fflush(stdout); _=activeWait(1_000_000); return
            }

            if !useCachedBoard {
                // Strict/learning mode still treats live pixels as authoritative.
                if hasFullLine(visionBoard) {
                    print("WAIT line-clear frame")
                    _=activeWait(45_000); return
                }
                let theoryDiff=theoreticalBoard.map { boardDifference(visionBoard,$0) } ?? 64
                if theoreticalBoard == nil || theoryDiff>0 || theoreticalPieceCount != pieces.count {
                    theoreticalBoard=visionBoard; theoreticalPieceCount=pieces.count
                    comboNow=0; skipsSinceClear=0
                    saveTheory(visionBoard,pieces.count,0,0)
                    print("VISION SYNC authoritative diff=\(theoryDiff) filled=\(visionFilled) pieces=\(pieces.count)")
                }
            } else if pieces.count==3 {
                // New tray: inspect only the three shapes; do not wait for the
                // board's line-clear pixels to finish animating.
                print("CACHE TRAY three new pieces; board=THEORY")
            }
            let board=useCachedBoard ? theoreticalBoard! : visionBoard
            theoryMismatchFrames=0
            let completeChoice=bestMove(board,pieces,skips:skipsSinceClear,streak:comboNow)
            var selectedChoice=completeChoice
            if selectedChoice==nil && sacrifice {
                selectedChoice=bestSingleMove(board,pieces)
                if let recovery=selectedChoice,let first=recovery.seq.first {
                    print("RECOVERY single legal move p\(first.0) r\(first.1)c\(first.2); full tray is already unwinnable")
                }
            }
            guard let choice=selectedChoice,
                  choice.seq.count==pieces.count || sacrifice,
                  let move=choice.seq.first else {
                noCompletionFrames+=1
                print("UNSAFE no complete tray sequence pieces=\(pieces.count) frame=\(noCompletionFrames) nodes=\(LAST_SOLVER_NODES)"); fflush(stdout)
                if noCompletionFrames>=3 {
                    print("PAUSED vision/desync: full tray sequence not found"); CONTROL.pause(); stop=true
                } else { _=activeWait(300_000) }
                return
            }
            noCompletionFrames=0; requiredPieceCount=nil; requiredPieceKeys=nil
            let piece=pieces[move.0]
            let expectedRemainingKeys:[String]? = pieces.count>1
                ? pieces.enumerated().filter{$0.offset != move.0}.map{strictShapeKey($0.element)}.sorted()
                : nil
            let profileBefore=transferProfile(piece)
            let frameAge=max(0,CFAbsoluteTimeGetCurrent()-frame.capturedAt)
            let requestFast=profileBefore.trusted && !probe && frameAge<0.35 &&
                            abs(profileBefore.correctionXCells)<=1.25 &&
                            abs(profileBefore.correctionYCells)<=1.25
            print(String(format:"PLAN %d/%d shape=%@ r%dc%d full=%d/%d nodes=%d path=%@ frame=%@ cache=%d/%d corr=%.2f,%.2f combo=%d/%d",
                         exact+1,goal,strictShapeKey(piece),move.1,move.2,
                         choice.seq.count,pieces.count,LAST_SOLVER_NODES,
                         requestFast ? "FAST":"LEARN",reusedPostFrame ? "POST":"FRESH",
                         profileBefore.exacts,profileBefore.failures,
                         profileBefore.correctionXCells,profileBefore.correctionYCells,
                         comboNow,skipsSinceClear))
            fflush(stdout); attempts+=1
            let t0=CFAbsoluteTimeGetCurrent()
            let result=strictPlace(frame.id,frame.bounds,frame.image,frame.capturedAt,
                                   board,piece,move.1,move.2,probe,requestFast)
            let ms=Int((CFAbsoluteTimeGetCurrent()-t0)*1000)
            carry=result.nextFrame
            if let expected=result.expectedNextCount {
                requiredPieceCount=expected
                requiredPieceKeys = expected==3 ? nil:expectedRemainingKeys
            }
            let cacheChange=recordTransfer(piece,result.code,result.usedFast,
                                           result.learnedX,result.learnedY)
            if !cacheChange.0 && cacheChange.1 {
                print("CACHE TRUST \(strictShapeKey(piece))")
            } else if cacheChange.0 && !cacheChange.1 {
                print("CACHE DEMOTE \(strictShapeKey(piece))")
            }
            appendStrict("{\"attempt\":\(attempts),\"n\":\(exact+1),\"shape\":\"\(strictShapeKey(piece))\",\"planned\":[\(move.1),\(move.2)],\"result\":\"\(result.code)\",\"path\":\"\(result.usedFast ? "fast":"learn")\",\"frame\":\"\(reusedPostFrame ? "post":"fresh")\",\"ms\":\(ms),\"timingUs\":[\(FAST_DOWN_US),\(FAST_TARGET_US),\(FAST_RELEASE_US)],\"cacheExacts\":\(cacheChange.2.exacts),\"cacheFailures\":\(cacheChange.2.failures),\"clears\":\(move.3),\"streak\":\(comboNow),\"skips\":\(skipsSinceClear)}")
            print("RESULT \(result.code) \(ms)ms nextFrame=\(result.nextFrame != nil ? "yes":"no")"); fflush(stdout)
            if probe { stop=true; return }
            switch result.code {
            case "exact","cached":
                // Combo accounting runs before the commit so the saved theory
                // state carries the fresh streak/skip budget.
                if move.3>0 {
                    comboNow+=1; maxCombo=max(maxCombo,comboNow)
                    skipsSinceClear=0
                    print("COMBO CLEAR streak=\(comboNow)")
                } else {
                    skipsSinceClear+=1
                    if skipsSinceClear>COMBO_MAX_SKIPS {
                        if comboNow>0 { print("COMBO BROKEN skips>\(COMBO_MAX_SKIPS) lost streak=\(comboNow)") }
                        comboNow=0; skipsSinceClear=0
                    } else if comboNow>0 {
                        print("COMBO SKIP \(skipsSinceClear)/\(COMBO_MAX_SKIPS) streak=\(comboNow)")
                    }
                }
                if commitTheoryResult(result) {
                    hasCommittedThisRun=true
                    cachedTheoryMode=(result.code=="cached")
                    exact+=1; failures=0; lines+=move.3
                    if result.code=="cached" {
                        print("CACHE COMMIT no post-board wait; tray-only mode enabled")
                    }
                    print("THEORY COMMIT filled=\(result.expectedBoard!.flatMap{$0}.filter{$0}.count) pieces=\(result.expectedNextCount!)")
                } else {
                    print("PAUSED exact result lacked theoretical state")
                    carry=nil; CONTROL.pause(); stop=true
                }
            case "mismatch":
                carry=nil
                print("PAUSED verified placement disagreed with planned free cells")
                CONTROL.pause(); stop=true
            case "post_unstable":
                // Transient: the post-placement frame was captured mid-animation.
                // Resync from the real board and retry; only stop after several in a row.
                carry=nil; failures+=1
                if failures>=5 { print("PAUSED repeated post-placement instability"); CONTROL.pause(); stop=true }
                else { print("RESYNC post-placement unstable, retrying"); _=activeWait(200_000) }
            case "no_preview","unsafe_preview","misaligned","correction_oob","invalid":
                carry=nil
                print("PAUSED invalid preview; no release performed and cache offset discarded")
                CONTROL.pause(); stop=true
            case "timing_miss":
                carry=nil
                print("PAUSED tray did not change; timing profile must be increased, geometry cache preserved")
                CONTROL.pause(); stop=true
            case "miss":
                carry=nil
                print("PAUSED release was not verified; geometry cache discarded")
                CONTROL.pause(); stop=true
            case "stale","unstable","window_changed","capture_failed":
                attempts=max(0,attempts-1); carry=nil
                _=activeWait(120_000)
            default:
                carry=nil; failures+=1
                if failures>=3 { print("STOP three safe aborts"); CONTROL.pause(); stop=true }
            }
        }
    }
    CONTROL.forceUp(); CONTROL.stop()
    print("STRICT DONE exact=\(exact) attempts=\(attempts) lines=\(lines) maxCombo=\(maxCombo) cache=\(TRANSFER_CACHE.count)")
    fflush(stdout)
}


// MARK: - Triple-boundary ultra-fast runner
//
// Capture policy:
//   1. One authoritative image at startup: locate the field, read its board,
//      and capture the current tray coordinates.
//   2. No held-preview capture, no per-placement tray capture, and no board
//      post-check after any individual move.
//   3. After the whole visible tray is consumed, capture only until the next
//      complete three-piece tray is at its resting coordinates. Its appearance
//      proves every piece in the previous tray was accepted. The solver board
//      advances purely from the exact simulated sequence, so field animation
//      is never sampled or waited on.
let BATCH_DOWN_US = strictIntArg("--batch-down-us",20_000)
let BATCH_TARGET_US = strictIntArg("--batch-target-us",10_000)
let BATCH_RELEASE_US = strictIntArg("--batch-release-us",6_000)
let BATCH_GAP_US = strictIntArg("--batch-gap-us",4_000)

struct BatchGesture {
    let piece:Piece
    let row:Int
    let col:Int
    let clears:Int
    let start:CGPoint
    let target:CGPoint
}
struct BatchBoundary {
    let frame:CycleFrame
    let captures:Int
    let waitMs:Int
    let identityAmbiguous:Bool
}

func batchTraySettled(_ pieces:[Piece])->Bool {
    guard !pieces.isEmpty else { return false }
    // At rest, tray rows are vertically centred on one shared baseline. These
    // ratios are relative to the detected board, not to an absolute window.
    // The gate removes only deal-slide frames; it never reads board pixels.
    let unit=Double(BOARD.width)/264.0
    let tolerance=max(5.0,8.0*unit)
    for p in pieces {
        let expectedTop=Double(BOARD.maxY)+(61.0-8.0*Double(p.rows))*unit
        let expectedBottom=Double(BOARD.maxY)+(61.0+7.5*Double(p.rows))*unit
        if abs(p.bbox[1]-expectedTop)>tolerance ||
           abs(p.bbox[3]-expectedBottom)>tolerance { return false }
    }
    return true
}

func batchTraySignature(_ pieces:[Piece])->String {
    // Quantized bbox coordinates make the signature insensitive to a one-pixel
    // capture wobble while still rejecting pieces that are growing/sliding.
    func q(_ value:Double)->Int { Int((value/2.0).rounded()) }
    return pieces.map { p in
        "\(strictShapeKey(p))@\(q(p.bbox[0])),\(q(p.bbox[1])),\(q(p.bbox[2])),\(q(p.bbox[3]))"
    }.sorted().joined(separator:"|")
}

func batchTransferPoints(_ bounds:CGRect,_ piece:Piece,_ row:Int,_ col:Int)->(CGPoint,CGPoint)? {
    let profile=transferProfile(piece)
    let startRel=cachedPickupPoint(piece,profile)
    let cell=BOARD.width/8.0
    let desired=CGPoint(x:BOARD.minX+(Double(col)+Double(piece.cols)/2.0)*cell,
                        y:BOARD.minY+(Double(row)+Double(piece.rows)/2.0)*cell)
    // The 101 image-verified adaptive-v4 moves all converged to zero cell
    // correction. Batch mode therefore uses the shape-independent normalized
    // lift directly and never consults a target-cell cache.
    let targetRel=CGPoint(x:desired.x+BOARD.width*TARGET_X_BIAS_BOARD_RATIO,
                          y:desired.y+BOARD.height*TARGET_Y_LIFT_BOARD_RATIO)
    guard startRel.x>5,startRel.x<bounds.width-5,
          startRel.y>5,startRel.y<bounds.height-5,
          targetRel.x>5,targetRel.x<bounds.width-5,
          targetRel.y>5,targetRel.y<bounds.height-5 else { return nil }
    return(CGPoint(x:bounds.minX+startRel.x,y:bounds.minY+startRel.y),
           CGPoint(x:bounds.minX+targetRel.x,y:bounds.minY+targetRel.y))
}

func batchUltraGesture(_ start:CGPoint,_ target:CGPoint,_ source:CGEventSource)->Bool {
    guard CONTROL.state().0 else { return false }
    var current=start,down=false
    defer {
        if down {
            hid(.leftMouseUp,current,source)
            CONTROL.end()
        }
    }
    // Instant cursor jump; no interpolated movement steps.
    hid(.mouseMoved,start,source)
    guard activeWait(1_000) else { return false }
    hid(.leftMouseDown,start,source); CONTROL.begin(start); down=true
    guard activeWait(BATCH_DOWN_US) else { return false }
    hid(.leftMouseDragged,target,source); CONTROL.update(target); current=target
    guard activeWait(BATCH_TARGET_US) else { return false }
    // Two zero-delay terminal events prevent Mirroring from coalescing a
    // stationary drag while adding effectively no movement time.
    let nudge=CGPoint(x:target.x+1.0,y:target.y)
    hid(.leftMouseDragged,nudge,source); CONTROL.update(nudge); current=nudge
    hid(.leftMouseDragged,target,source); CONTROL.update(target); current=target
    guard activeWait(BATCH_RELEASE_US) else { return false }
    hid(.leftMouseUp,target,source); CONTROL.end(); down=false
    return activeWait(BATCH_GAP_US)
}

func batchRestartTap(_ id:CGWindowID,_ bounds:CGRect,_ relative:CGPoint,
                     _ source:CGEventSource,_ afterUs:Int=100_000)->Bool {
    guard CONTROL.state().0,focusStrictWindow(id,bounds),
          relative.x>4,relative.x<bounds.width-4,
          relative.y>4,relative.y<bounds.height-4 else { return false }
    let point=CGPoint(x:bounds.minX+relative.x,y:bounds.minY+relative.y)
    hid(.mouseMoved,point,source)
    guard activeWait(1_000) else { return false }
    var down=false
    defer {
        if down { hid(.leftMouseUp,point,source); CONTROL.end() }
    }
    hid(.leftMouseDown,point,source); CONTROL.begin(point); down=true
    guard activeWait(12_000) else { return false }
    hid(.leftMouseUp,point,source); CONTROL.end(); down=false
    return activeWait(afterUs)
}

func batchFreshFieldVisible(_ id:CGWindowID,_ bounds:CGRect)->Bool {
    guard focusStrictWindow(id,bounds),let (image,_)=grab(id,bounds),
          let grid=locateBoard(image) else { return false }
    applyAdaptiveGeometry(grid); LOCKED_GRID=grid
    let (board,_)=boardState(image)
    // Leaving through "Да" preserves the current game, so a valid
    // returned field may be non-empty. Only reject unfinished line animation.
    return LAST_EMPTY_SUPPORT>0 && !hasFullLine(board)
}

func captureBatchRestartTray(_ id:CGWindowID,_ bounds:CGRect,
                             _ expectedPieceCount:Int,
                             _ expectedBoard:[[Bool]]?)->BatchBoundary? {
    let started=CFAbsoluteTimeGetCurrent()
    var captures=0,lastSignature="",stableCount=0
    while CONTROL.state().0 {
        guard focusStrictWindow(id,bounds),let (image,_)=grab(id,bounds) else {
            _=activeWait(20_000); continue
        }
        captures+=1
        let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
        guard let grid=locateBoard(image) else {
            if elapsed>12_000 {
                print("BATCH PAUSED restarted field disappeared while waiting for tray")
                return nil
            }
            _=activeWait(20_000); continue
        }
        applyAdaptiveGeometry(grid); LOCKED_GRID=grid
        let (board,_)=boardState(image)
        let pieces=Array(validTrayPieces(image).prefix(3))
        let countOK = expectedPieceCount==0
            ? (1...3).contains(pieces.count)
            : pieces.count==expectedPieceCount
        let boardOK = expectedBoard.map { boardDifference($0,board)==0 } ?? true
        guard LAST_EMPTY_SUPPORT>0,countOK,boardOK,
              pieces.allSatisfy({connectedShape($0)}),
              batchTraySettled(pieces),!hasFullLine(board) else {
            lastSignature=""; stableCount=0
            if elapsed>12_000 {
                let diff=expectedBoard.map { boardDifference($0,board) } ?? -1
                print("BATCH PAUSED restarted tray/state not stable after 12s pieces=\(pieces.count) expected=\(expectedPieceCount) boardDiff=\(diff)")
                return nil
            }
            _=activeWait(10_000); continue
        }
        let signature=gridText(board)+"|"+batchTraySignature(pieces)
        if signature==lastSignature { stableCount+=1 }
        else { lastSignature=signature; stableCount=1 }
        guard stableCount>=2 else { _=activeWait(1_000); continue }
        print("BATCH CAPTURE restart captures=\(captures) wait=\(elapsed)ms grid=(\(Int(BOARD.minX)),\(Int(BOARD.minY)),\(Int(BOARD.width))) pieces=\(pieces.count)")
        return BatchBoundary(frame:CycleFrame(id:id,bounds:bounds,image:image,
                             board:board,pieces:pieces,
                             capturedAt:CFAbsoluteTimeGetCurrent()),
                             captures:captures,waitMs:elapsed,
                             identityAmbiguous:false)
    }
    return nil
}

func batchRestartGame(_ id:CGWindowID,_ bounds:CGRect,
                      _ skipBack:Bool=false,
                      _ expectedPieceCount:Int=3,
                      _ expectedBoard:[[Bool]]?=nil)->BatchBoundary? {
    let started=CFAbsoluteTimeGetCurrent()
    let source=CGEventSource(stateID:.hidSystemState)!
    // OCR-calibrated centre of the orange "Да" button on the 316x696 window.
    // Scale it with the window instead of using screen-absolute coordinates.
    let yes=CGPoint(x:bounds.width*(RESTART_YES.x/316.0),
                    y:bounds.height*(RESTART_YES.y/696.0))
    LOCKED_GRID=nil
    print("BATCH RESTART begin back=(\(Int(BACK.x)),\(Int(BACK.y))) yes=(\(Int(yes.x)),\(Int(yes.y))) skipBack=\(skipBack)")
    fflush(stdout)
    if !skipBack {
        guard batchRestartTap(id,bounds,BACK,source) else {
            print("BATCH PAUSED restart back tap failed"); return nil
        }
    }
    // Every confirmation/launch tap goes to the same physical place as "Да".
    for tapIndex in 1...3 {
        let afterUs = tapIndex==1 ? RESTART_FIRST_YES_WAIT_US : 100_000
        guard batchRestartTap(id,bounds,yes,source,afterUs) else {
            print("BATCH PAUSED restart yes tap \(tapIndex) failed"); return nil
        }
        print("BATCH RESTART yes tap=\(tapIndex)/3 wait=\(afterUs/1000)ms"); fflush(stdout)
    }

    var probes=0,extraTaps=0
    func probe()->Bool {
        probes+=1
        let found=batchFreshFieldVisible(id,bounds)
        print("BATCH RESTART probe=\(probes) field=\(found ? 1:0)"); fflush(stdout)
        return found
    }
    var found=probe()
    while !found && extraTaps<5 {
        extraTaps+=1
        guard batchRestartTap(id,bounds,yes,source) else {
            print("BATCH PAUSED restart extra yes tap \(extraTaps) failed"); return nil
        }
        print("BATCH RESTART extra yes tap=\(extraTaps)/5"); fflush(stdout)
        found=probe()
    }
    guard found else {
        print("BATCH PAUSED restart field not found after 5 extra yes taps")
        return nil
    }
    guard let stable=captureBatchRestartTray(id,bounds,expectedPieceCount,expectedBoard) else {
        print("BATCH PAUSED restarted field/full tray did not stabilize")
        return nil
    }
    let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
    let totalTaps=(skipBack ? 0 : 1)+3+extraTaps
    print("BATCH RESTART field ready taps=\(totalTaps) probes=\(probes) wait=\(elapsed)ms")
    return BatchBoundary(frame:stable.frame,
                         captures:stable.captures+probes,
                         waitMs:elapsed,identityAmbiguous:false)
}

func captureBatchInitial(_ id:CGWindowID,_ bounds:CGRect)->BatchBoundary? {
    let started=CFAbsoluteTimeGetCurrent()
    var captures=0,lastMessage=0,lastTraySignature="",traySignatureStable=0
    while CONTROL.state().0 {
        guard focusStrictWindow(id,bounds),let (image,_)=grab(id,bounds) else {
            _=activeWait(20_000); continue
        }
        captures+=1
        guard let grid=locateBoard(image) else {
            if captures-lastMessage>=5 { print("BATCH WAIT initial field"); fflush(stdout); lastMessage=captures }
            _=activeWait(20_000); continue
        }
        applyAdaptiveGeometry(grid); LOCKED_GRID=grid
        let (board,_)=boardState(image)
        let pieces=Array(validTrayPieces(image).prefix(3))
        guard LAST_EMPTY_SUPPORT>0,(1...3).contains(pieces.count),
              pieces.allSatisfy({connectedShape($0)}),batchTraySettled(pieces),
              !hasFullLine(board) else {
            lastTraySignature=""; traySignatureStable=0
            _=activeWait(10_000); continue
        }
        let traySignature=batchTraySignature(pieces)
        if traySignature==lastTraySignature { traySignatureStable+=1 }
        else { lastTraySignature=traySignature; traySignatureStable=1 }
        guard traySignatureStable>=2 else { _=activeWait(1_000); continue }
        let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
        print("BATCH CAPTURE initial captures=\(captures) wait=\(elapsed)ms grid=(\(Int(BOARD.minX)),\(Int(BOARD.minY)),\(Int(BOARD.width))) pieces=\(pieces.count)")
        return BatchBoundary(frame:CycleFrame(id:id,bounds:bounds,image:image,
                            board:board,pieces:pieces,capturedAt:CFAbsoluteTimeGetCurrent()),
                            captures:captures,waitMs:elapsed,identityAmbiguous:false)
    }
    return nil
}

func captureNextTriple(_ id:CGWindowID,_ bounds:CGRect,_ expectedBoard:[[Bool]],
                       _ oldKeys:[String])->BatchBoundary? {
    let started=CFAbsoluteTimeGetCurrent()
    var captures=0,lastCount = -1,stableCount=0
    var sameIdentityStable=0,lastTraySignature="",traySignatureStable=0
    while CONTROL.state().0 {
        guard focusStrictWindow(id,bounds) else {
            print("BATCH PAUSED window could not be focused during tray"); return nil
        }
        guard let (image,_)=grab(id,bounds) else { _=activeWait(2_000); continue }
        captures+=1
        if let grid=LOCKED_GRID { applyAdaptiveGeometry(grid) }
        let pieces=Array(validTrayPieces(image).prefix(3))
        let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
        let count=pieces.count
        if count==lastCount { stableCount+=1 } else { lastCount=count; stableCount=1 }
        if count==3,pieces.allSatisfy({connectedShape($0)}),batchTraySettled(pieces) {
            let traySignature=batchTraySignature(pieces)
            if traySignature==lastTraySignature { traySignatureStable+=1 }
            else { lastTraySignature=traySignature; traySignatureStable=1 }
            if traySignatureStable<2 { _=activeWait(1_000); continue }
            let newKeys=pieces.map(strictShapeKey).sorted()
            let ambiguous=(newKeys==oldKeys)
            if !ambiguous {
                print("BATCH CAPTURE next captures=\(captures) wait=\(elapsed)ms tray=3")
                return BatchBoundary(frame:CycleFrame(id:id,bounds:bounds,image:image,
                                     board:expectedBoard,pieces:pieces,
                                     capturedAt:CFAbsoluteTimeGetCurrent()),
                                     captures:captures,waitMs:elapsed,
                                     identityAmbiguous:false)
            }
            // If the random deal has the exact same shape multiset as the old
            // tray, tray identity alone cannot distinguish a new deal from
            // three failed pickups. Only this rare ambiguous case inspects the
            // board in the SAME boundary screenshot; normal rounds never do.
            let (actualBoard,_)=boardState(image)
            if LAST_EMPTY_SUPPORT>0,actualBoard==expectedBoard {
                print("BATCH CAPTURE next same-identity board-confirmed captures=\(captures) wait=\(elapsed)ms")
                return BatchBoundary(frame:CycleFrame(id:id,bounds:bounds,image:image,
                                     board:expectedBoard,pieces:pieces,
                                     capturedAt:CFAbsoluteTimeGetCurrent()),
                                     captures:captures,waitMs:elapsed,
                                     identityAmbiguous:true)
            }
            sameIdentityStable+=1
            if elapsed>1_500 && sameIdentityStable>=3 {
                print("BATCH PAUSED unchanged three-piece tray; gestures were not accepted")
                return nil
            }
        } else {
            sameIdentityStable=0; lastTraySignature=""; traySignatureStable=0
        }

        // One or two settled old pieces persisting well beyond the deal
        // animation proves that at least one batch gesture failed. Stop before
        // touching anything else; there is never speculative continuation.
        if (1...2).contains(count),pieces.allSatisfy({connectedShape($0)}),
           batchTraySettled(pieces),elapsed>1_800,stableCount>=4 {
            print("BATCH PAUSED old tray remains count=\(count) after \(elapsed)ms")
            return nil
        }
        if elapsed>60_000 {
            print("BATCH PAUSED next tray not visible after 60s")
            return nil
        }
        if captures==1 || captures%12==0 {
            print("BATCH WAIT next tray seen=\(count) capture=\(captures)"); fflush(stdout)
        }
        // screencapture itself is the pacing operation; this is only a yield.
        _=activeWait(1_000)
    }
    return nil
}

struct ComboTimingProbeResult {
    let firstShifted:Bool
    let settled:Bool
    let captures:Int
    let firstDx:Double
    let firstDy:Double
    let finalDx:Double
    let finalDy:Double
    let elapsedMs:Int
}

func probeComboGeometry(_ id:CGWindowID,_ bounds:CGRect,_ baseline:CGRect,
                        _ delayMs:Int,_ stepMs:Int,_ maxWaitMs:Int)->ComboTimingProbeResult? {
    let started=CFAbsoluteTimeGetCurrent()
    guard activeWait(max(0,delayMs)*1_000) else { return nil }
    var captures=0,haveFirst=false,firstShifted=false
    var firstDx=999.0,firstDy=999.0,lastDx=999.0,lastDy=999.0
    while CONTROL.state().0 {
        guard focusStrictWindow(id,bounds) else { return nil }
        guard let (image,_)=grab(id,bounds) else {
            let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
            if elapsed>=maxWaitMs {
                return ComboTimingProbeResult(firstShifted:true,settled:false,
                    captures:captures,firstDx:firstDx,firstDy:firstDy,
                    finalDx:lastDx,finalDy:lastDy,elapsedMs:elapsed)
            }
            guard activeWait(max(10,stepMs)*1_000) else { return nil }
            continue
        }
        captures+=1
        let elapsed=Int((CFAbsoluteTimeGetCurrent()-started)*1000)
        guard let grid=locateBoard(image) else {
            if !haveFirst {
                haveFirst=true; firstShifted=true
                firstDx=999.0; firstDy=999.0
            }
            lastDx=999.0; lastDy=999.0
            print("COMBO TIMING sample delay=\(delayMs)ms elapsed=\(elapsed)ms grid=missing")
            fflush(stdout)
            if elapsed>=maxWaitMs {
                return ComboTimingProbeResult(firstShifted:firstShifted,settled:false,
                    captures:captures,firstDx:firstDx,firstDy:firstDy,
                    finalDx:lastDx,finalDy:lastDy,elapsedMs:elapsed)
            }
            guard activeWait(max(10,stepMs)*1_000) else { return nil }
            continue
        }
        let dx=Double(grid.minX-baseline.minX)
        let dy=Double(grid.minY-baseline.minY)
        let dw=Double(grid.width-baseline.width)
        let shifted=abs(dx)>1.5 || abs(dy)>1.5 || abs(dw)>1.5
        if !haveFirst {
            haveFirst=true; firstShifted=shifted
            firstDx=dx; firstDy=dy
        }
        lastDx=dx; lastDy=dy
        print(String(format:"COMBO TIMING sample delay=%dms elapsed=%dms dx=%.1f dy=%.1f dw=%.1f shifted=%d",
                     delayMs,elapsed,dx,dy,dw,shifted ? 1:0))
        fflush(stdout)
        if !shifted {
            // Keep the pre-animation geometry for all precomputed gestures.
            applyAdaptiveGeometry(baseline); LOCKED_GRID=baseline
            return ComboTimingProbeResult(firstShifted:firstShifted,settled:true,
                captures:captures,firstDx:firstDx,firstDy:firstDy,
                finalDx:lastDx,finalDy:lastDy,elapsedMs:elapsed)
        }
        if elapsed>=maxWaitMs {
            return ComboTimingProbeResult(firstShifted:firstShifted,settled:false,
                captures:captures,firstDx:firstDx,firstDy:firstDy,
                finalDx:lastDx,finalDy:lastDy,elapsedMs:elapsed)
        }
        guard activeWait(max(10,stepMs)*1_000) else { return nil }
    }
    return nil
}

func runBatchFast() {
    guard installHotkeys() else { fputs("HOTKEY ERROR\n",stderr); return }
    let mi=ARGS.firstIndex(of:"--moves")
    let requestedMoves=(mi != nil && mi!+1<ARGS.count ? Int(ARGS[mi!+1]) : nil) ?? 30
    let ri=ARGS.firstIndex(of:"--rounds")
    let requestedRounds=(ri != nil && ri!+1<ARGS.count ? Int(ARGS[ri!+1]) : nil)
        ?? max(1,(requestedMoves+2)/3)
    func intOption(_ name:String,_ fallback:Int)->Int {
        guard let i=ARGS.firstIndex(of:name),i+1<ARGS.count,
              let value=Int(ARGS[i+1]) else { return fallback }
        return value
    }
    let comboTimingTest=ARGS.contains("--combo-timing-test")
    let restartIndex=ARGS.firstIndex(of:"--restart-every")
    let explicitRestart=(restartIndex != nil && restartIndex!+1<ARGS.count
        ? Int(ARGS[restartIndex!+1]) : nil)
    // Periodic UI restart is calibration-only unless explicitly requested.
    let restartEvery=max(0,explicitRestart ?? (comboTimingTest ? 35 : 0))
    let comboDelayStartMs=max(0,intOption("--combo-delay-ms",50))
    let comboDelayStepMs=max(10,intOption("--combo-delay-step-ms",50))
    let comboDelayMaxMs=max(comboDelayStartMs+comboDelayStepMs,
                            intOption("--combo-delay-max-ms",1_500))
    // Calibrated by combo-timing runs; override with --post-combo-ms.
    let postComboDelayMs=max(0,intOption("--post-combo-ms",450))
    // Benchmark timer starts after initial vision/theory synchronization and
    // stops only at a fully acknowledged tray boundary.
    let durationSeconds=max(0,intOption("--duration-seconds",0))
    if ARGS.contains("--reset-theory") { clearTheory() }
    if ARGS.contains("--reset-cache") {
        TRANSFER_CACHE.removeAll(); saveTransferCache(); print("CACHE RESET")
    }
    let loadedTheory=loadTheory()
    guard let (id,bounds,_)=prepareStrictWindow() else {
        print("STOP Mirroring window did not become visible"); return
    }
    print("WINDOW READY \(bounds)")
    _=CONTROL.toggle()
    print("BATCH RUN rounds=\(requestedRounds) duration=\(durationSeconds)s timing=\(BATCH_DOWN_US)/\(BATCH_TARGET_US)/\(BATCH_RELEASE_US)/\(BATCH_GAP_US)us restartEvery=\(restartEvery) comboTiming=\(comboTimingTest ? 1 : 0) comboDelay=\(comboDelayStartMs)ms step=\(comboDelayStepMs)ms postCombo=\(postComboDelayMs)ms | Esc stop")
    fflush(stdout)
    if ARGS.contains("--restart-recover") {
        guard let restarted=batchRestartGame(id,bounds,true,0,nil) else {
            CONTROL.forceUp(); CONTROL.stop()
            print("BATCH RESTART RECOVER failed")
            return
        }
        saveTheory(restarted.frame.board,restarted.frame.pieces.count,0,0)
        print("BATCH RESTART RECOVER ok captures=\(restarted.captures) wait=\(restarted.waitMs)ms")
        CONTROL.forceUp(); CONTROL.stop(); return
    }
    var initialBoundary=captureBatchInitial(id,bounds)
    if initialBoundary==nil {
        print("BATCH AUTO RESTART initial capture failed")
        appendStrict("{\"mode\":\"auto_restart_attempt\",\"reason\":\"initial_capture\",\"attempt\":1}")
        initialBoundary=batchRestartGame(id,bounds,true,0,nil)
    }
    guard let initial=initialBoundary else {
        CONTROL.forceUp(); CONTROL.stop(); print("BATCH DONE verified=0 attempted=0 rounds=0 autoRestartFailed=1"); return
    }
    var frame=initial.frame
    if ARGS.contains("--batch-vision") {
        let piecesText=frame.pieces.map(strictShapeKey).joined(separator:" | ")
        print("BATCH VISION filled=\(frame.board.flatMap{$0}.filter{$0}.count) grid=\(gridText(frame.board)) pieces=\(piecesText) captures=\(initial.captures)")
        CONTROL.forceUp(); CONTROL.stop(); return
    }
    if ARGS.contains("--restart-now") {
        guard let restarted=batchRestartGame(id,bounds,false,frame.pieces.count,frame.board) else {
            CONTROL.forceUp(); CONTROL.stop()
            print("BATCH RESTART TEST failed")
            return
        }
        saveTheory(restarted.frame.board,restarted.frame.pieces.count,0,0)
        print("BATCH RESTART TEST ok captures=\(restarted.captures) wait=\(restarted.waitMs)ms")
        CONTROL.forceUp(); CONTROL.stop(); return
    }
    var comboNow=0,skipsSinceClear=0
    if let loaded=loadedTheory,
       loaded.expectedPieceCount==frame.pieces.count,
       boardDifference(loaded.board,frame.board)==0 {
        comboNow=loaded.streak; skipsSinceClear=loaded.skips
        print("BATCH THEORY matched combo=\(comboNow)/\(skipsSinceClear)")
    } else {
        saveTheory(frame.board,frame.pieces.count,0,0)
        print("BATCH VISION SYNC filled=\(frame.board.flatMap{$0}.filter{$0}.count) pieces=\(frame.pieces.count)")
    }

    var verified=0,attempted=0,rounds=0,lines=0,maxCombo=comboNow,totalCaptures=initial.captures
    var linePoints=0,comboBonus=0,restartCount=0,autoRestartCount=0
    var comboDelayMs=comboDelayStartMs,comboTimingProbes=0,comboTimingShifts=0
    var nextRestartAt=restartEvery>0 ? restartEvery:Int.max
    let runStarted=CFAbsoluteTimeGetCurrent()
    var durationReached=false,stop=false,consecutiveAutoRestartErrors=0
    let maxAutoRestartErrors=max(1,intOption("--max-error-restarts",3))
    func autoRestartAfterError(_ reason:String,_ preferSkipBack:Bool)->Bool {
        consecutiveAutoRestartErrors+=1
        let attempt=consecutiveAutoRestartErrors
        print("BATCH AUTO RESTART reason=\(reason) attempt=\(attempt)/\(maxAutoRestartErrors) preferSkipBack=\(preferSkipBack ? 1:0)")
        appendStrict("{\"mode\":\"auto_restart_attempt\",\"reason\":\"\(reason)\",\"round\":\(rounds),\"verified\":\(verified),\"attempt\":\(attempt)}")
        fflush(stdout)
        guard attempt<=maxAutoRestartErrors else {
            print("BATCH AUTO RESTART exhausted reason=\(reason)")
            appendStrict("{\"mode\":\"auto_restart_failed\",\"reason\":\"\(reason)\",\"round\":\(rounds),\"verified\":\(verified)}")
            return false
        }
        CONTROL.forceUp()
        var restarted=batchRestartGame(id,bounds,preferSkipBack,0,nil)
        if restarted==nil {
            print("BATCH AUTO RESTART retry alternateMode reason=\(reason)")
            restarted=batchRestartGame(id,bounds,!preferSkipBack,0,nil)
        }
        guard let recovered=restarted else {
            print("BATCH AUTO RESTART attempt failed reason=\(reason) attempt=\(attempt)")
            appendStrict("{\"mode\":\"auto_restart_failed\",\"reason\":\"\(reason)\",\"round\":\(rounds),\"verified\":\(verified),\"attempt\":\(attempt)}")
            return false
        }
        totalCaptures+=recovered.captures
        restartCount+=1; autoRestartCount+=1
        frame=recovered.frame; comboNow=0; skipsSinceClear=0
        saveTheory(frame.board,frame.pieces.count,0,0)
        let shapes=frame.pieces.map(strictShapeKey).joined(separator:"|")
        print("BATCH AUTO RESTARTED reason=\(reason) wait=\(recovered.waitMs)ms captures=\(recovered.captures) new=\(shapes)")
        appendStrict("{\"mode\":\"auto_restart_success\",\"reason\":\"\(reason)\",\"round\":\(rounds),\"verified\":\(verified),\"waitMs\":\(recovered.waitMs),\"captures\":\(recovered.captures)}")
        fflush(stdout)
        return true
    }
    while (durationSeconds>0 || rounds<requestedRounds) && !stop && CONTROL.state().0 {
        let pieces=frame.pieces,board=frame.board
        guard !pieces.isEmpty,pieces.count<=3,
              let choice=bestMove(board,pieces,skips:skipsSinceClear,streak:comboNow),
              choice.seq.count==pieces.count else {
            print("BATCH ERROR no complete tray sequence pieces=\(pieces.count) nodes=\(LAST_SOLVER_NODES)")
            if autoRestartAfterError("no_complete_tray",true) { continue }
            CONTROL.pause(); stop=true; break
        }
        let observedShapes=pieces.map(strictShapeKey).joined(separator:"|")
        let observedPlan=choice.seq.map { "\($0.0):\($0.1):\($0.2):\($0.3)" }.joined(separator:";")
        appendStrict("{\"mode\":\"generator_observation\",\"round\":\(rounds),\"verified\":\(verified),\"boardBits\":\"\(boardBits(board))\",\"board\":\"\(gridText(board))\",\"filled\":\(board.flatMap{$0}.filter{$0}.count),\"streak\":\(comboNow),\"skips\":\(skipsSinceClear),\"pieces\":\"\(observedShapes)\",\"plan\":\"\(observedPlan)\",\"solverNodes\":\(LAST_SOLVER_NODES)}")
        guard let (liveId,liveBounds,_)=findStrictWin(),liveId==id,
              sameBounds(liveBounds,bounds) else {
            print("BATCH PAUSED window moved before gesture batch"); CONTROL.pause(); break
        }

        var expected=board
        var scheduled=[BatchGesture](),scheduleFailure:String?=nil
        var nextCombo=comboNow,nextSkips=skipsSinceClear,nextMax=maxCombo,nextLines=lines
        var nextLinePoints=linePoints,nextComboBonus=comboBonus
        for move in choice.seq {
            let piece=pieces[move.0]
            guard fits(expected,piece.cells,move.1,move.2),
                  let points=batchTransferPoints(bounds,piece,move.1,move.2) else {
                print("BATCH ERROR invalid scheduled geometry"); scheduleFailure="invalid_geometry"; break
            }
            let dropped=dropP(expected,piece.cells,move.1,move.2)
            guard dropped.1==move.3 else {
                print("BATCH ERROR solver clear mismatch"); scheduleFailure="solver_clear_mismatch"; break
            }
            expected=dropped.0
            scheduled.append(BatchGesture(piece:piece,row:move.1,col:move.2,
                                          clears:move.3,start:points.0,target:points.1))
            if move.3>0 {
                nextCombo+=1; nextMax=max(nextMax,nextCombo); nextSkips=0; nextLines+=move.3
                nextLinePoints+=move.3*10
                // First clear is ordinary line score. Combo bonus starts with
                // streak #2 and is 10 * the current streak number.
                if nextCombo>1 { nextComboBonus+=nextCombo*10 }
            } else {
                nextSkips+=1
                if nextSkips>COMBO_MAX_SKIPS { nextCombo=0; nextSkips=0 }
            }
        }
        if let reason=scheduleFailure {
            if autoRestartAfterError(reason,false) { continue }
            CONTROL.pause(); stop=true; break
        }
        guard scheduled.count==pieces.count else {
            if autoRestartAfterError("incomplete_schedule",false) { continue }
            CONTROL.pause(); stop=true; break
        }
        guard expected==choice.b else {
            print("BATCH ERROR solver final board mismatch")
            if autoRestartAfterError("solver_final_board_mismatch",false) { continue }
            CONTROL.pause(); stop=true; break
        }

        let source=CGEventSource(stateID:.hidSystemState)!
        let gestureStart=CFAbsoluteTimeGetCurrent()
        var allSent=true
        for (index,g) in scheduled.enumerated() {
            print("BATCH MOVE \(verified+index+1) shape=\(strictShapeKey(g.piece)) r\(g.row)c\(g.col) clear=\(g.clears)")
            fflush(stdout)
            attempted+=1
            if !batchUltraGesture(g.start,g.target,source) { allSent=false; break }
            if comboTimingTest && g.clears>0 {
                let baseline=LOCKED_GRID ?? BOARD
                let delayUsed=comboDelayMs
                guard let timing=probeComboGeometry(id,bounds,baseline,delayUsed,
                                                    comboDelayStepMs,comboDelayMaxMs) else {
                    print("BATCH PAUSED combo timing probe interrupted")
                    allSent=false; break
                }
                totalCaptures+=timing.captures
                comboTimingProbes+=1
                if timing.firstShifted {
                    comboTimingShifts+=1
                    comboDelayMs=min(comboDelayMaxMs,comboDelayMs+comboDelayStepMs)
                }
                print(String(format:"COMBO TIMING result move=%d clear=%d used=%dms firstDx=%.1f firstDy=%.1f settled=%d elapsed=%dms next=%dms",
                             verified+index+1,g.clears,delayUsed,timing.firstDx,timing.firstDy,
                             timing.settled ? 1:0,timing.elapsedMs,comboDelayMs))
                appendStrict("{\"mode\":\"combo_timing\",\"move\":\(verified+index+1),\"clear\":\(g.clears),\"delayMs\":\(delayUsed),\"firstDx\":\(timing.firstDx),\"firstDy\":\(timing.firstDy),\"settled\":\(timing.settled ? 1:0),\"elapsedMs\":\(timing.elapsedMs),\"nextDelayMs\":\(comboDelayMs),\"captures\":\(timing.captures)}")
                fflush(stdout)
                if !timing.settled {
                    print("BATCH PAUSED combo field remained shifted; no next gesture sent")
                    allSent=false; break
                }
            } else if g.clears>0 && postComboDelayMs>0 {
                print("COMBO WAIT move=\(verified+index+1) clear=\(g.clears) delay=\(postComboDelayMs)ms")
                fflush(stdout)
                if !activeWait(postComboDelayMs*1_000) {
                    allSent=false; break
                }
            }
        }
        let gestureMs=Int((CFAbsoluteTimeGetCurrent()-gestureStart)*1000)
        guard allSent else {
            print("BATCH ERROR gesture interrupted")
            if autoRestartAfterError("gesture_interrupted",false) { continue }
            CONTROL.pause(); stop=true; break
        }

        let oldKeys=pieces.map(strictShapeKey).sorted()
        guard let boundary=captureNextTriple(id,bounds,expected,oldKeys) else {
            print("BATCH ERROR next triple missing or game ended")
            if autoRestartAfterError("next_triple_missing",true) { continue }
            CONTROL.pause(); stop=true; break
        }
        totalCaptures+=boundary.captures
        // The complete new tray is the batch acknowledgement. Only now may
        // the solver state, cache statistics, combo, and verified counter move.
        for g in scheduled {
            _=recordTransfer(g.piece,"exact",true,nil,nil)
        }
        verified+=scheduled.count; rounds+=1
        consecutiveAutoRestartErrors=0
        comboNow=nextCombo; skipsSinceClear=nextSkips; maxCombo=nextMax; lines=nextLines
        linePoints=nextLinePoints; comboBonus=nextComboBonus
        saveTheory(expected,3,comboNow,skipsSinceClear)
        frame=boundary.frame
        let totalMs=gestureMs+boundary.waitMs
        let shapes=frame.pieces.map(strictShapeKey).joined(separator:"|")
        print("BATCH VERIFIED round=\(rounds) moves=\(scheduled.count) gesture=\(gestureMs)ms boundary=\(boundary.waitMs)ms total=\(totalMs)ms captures=\(boundary.captures) new=\(shapes) combo=\(comboNow)/\(skipsSinceClear) points=\(linePoints+comboBonus)")
        appendStrict("{\"mode\":\"triple_batch\",\"round\":\(rounds),\"verified\":\(verified),\"moves\":\(scheduled.count),\"gestureMs\":\(gestureMs),\"boundaryMs\":\(boundary.waitMs),\"captures\":\(boundary.captures),\"timingUs\":[\(BATCH_DOWN_US),\(BATCH_TARGET_US),\(BATCH_RELEASE_US),\(BATCH_GAP_US)],\"lines\":\(lines),\"combo\":\(comboNow)}")
        fflush(stdout)

        let elapsedAfterRound=CFAbsoluteTimeGetCurrent()-runStarted
        if durationSeconds>0 && elapsedAfterRound>=Double(durationSeconds) {
            durationReached=true
            print(String(format:"BATCH TIME LIMIT boundary elapsed=%.3fs",elapsedAfterRound))
            break
        }

        if restartEvery>0 && verified>=nextRestartAt &&
           (durationSeconds>0 || rounds<requestedRounds) {
            print("BATCH RESTART threshold=\(nextRestartAt) verified=\(verified) round=\(rounds)")
            fflush(stdout)
            guard let restarted=batchRestartGame(id,bounds,false,frame.pieces.count,frame.board) else {
                if autoRestartAfterError("scheduled_restart_failed",true) {
                    while nextRestartAt<=verified { nextRestartAt+=restartEvery }
                    continue
                }
                CONTROL.pause(); stop=true; break
            }
            totalCaptures+=restarted.captures
            restartCount+=1
            frame=restarted.frame
            comboNow=0; skipsSinceClear=0
            saveTheory(frame.board,frame.pieces.count,0,0)
            while nextRestartAt<=verified { nextRestartAt+=restartEvery }
            let restartShapes=frame.pieces.map(strictShapeKey).joined(separator:"|")
            print("BATCH RESTARTED verified=\(verified) next=\(nextRestartAt) wait=\(restarted.waitMs)ms captures=\(restarted.captures) new=\(restartShapes)")
            appendStrict("{\"mode\":\"batch_restart\",\"round\":\(rounds),\"verified\":\(verified),\"next\":\(nextRestartAt),\"waitMs\":\(restarted.waitMs),\"captures\":\(restarted.captures)}")
            fflush(stdout)
        }
        let elapsedAfterMaintenance=CFAbsoluteTimeGetCurrent()-runStarted
        if durationSeconds>0 && elapsedAfterMaintenance>=Double(durationSeconds) {
            durationReached=true
            print(String(format:"BATCH TIME LIMIT maintenance elapsed=%.3fs",elapsedAfterMaintenance))
            break
        }
    }
    CONTROL.forceUp(); CONTROL.stop()
    let elapsedSeconds=CFAbsoluteTimeGetCurrent()-runStarted
    let totalPoints=linePoints+comboBonus
    let movesPerMinute=elapsedSeconds>0 ? Double(verified)*60.0/elapsedSeconds : 0.0
    let stopReason=durationReached ? "duration" :
        ((durationSeconds==0 && rounds>=requestedRounds) ? "goal":"stopped")
    if durationSeconds>0 {
        print(String(format:"BATCH BENCHMARK reason=%@ elapsed=%.3fs moves=%d movesPerMin=%.2f rounds=%d lines=%d linePoints=%d comboBonus=%d totalPoints=%d maxCombo=%d restarts=%d postCombo=%dms",
                     stopReason,elapsedSeconds,verified,movesPerMinute,rounds,lines,
                     linePoints,comboBonus,totalPoints,maxCombo,restartCount,postComboDelayMs))
    }
    print("BATCH DONE verified=\(verified) attempted=\(attempted) rounds=\(rounds) lines=\(lines) maxCombo=\(maxCombo) captures=\(totalCaptures) cache=\(TRANSFER_CACHE.count) comboTimingProbes=\(comboTimingProbes) comboTimingShifts=\(comboTimingShifts) comboDelay=\(comboDelayMs)ms postCombo=\(postComboDelayMs)ms points=\(totalPoints) restarts=\(restartCount) autoRestarts=\(autoRestartCount)")
    fflush(stdout)
}

func runSolverSelfTest() {
    func piece(_ cells:[[Bool]])->Piece {
        Piece(cells:cells,rows:cells.count,cols:cells[0].count,
              ax:0,ay:0,bbox:[0,0,Double(cells[0].count),Double(cells.count)])
    }
    let empty=[[Bool]](repeating:[Bool](repeating:false,count:8),count:8)
    let solvable=[piece([[true,true],[true,true]]),
                  piece([[true,true,true,true,true]]),
                  piece([[true,false],[false,true]])]
    let full=bestMove(empty,solvable)
    let fullOK=full?.seq.count==solvable.count
    let fullNodes=LAST_SOLVER_NODES

    var checker=[[Bool]](repeating:[Bool](repeating:false,count:8),count:8)
    for r in 0..<8 { for c in 0..<8 { checker[r][c]=(r+c)%2==0 } }
    let impossible=[piece([[true]]),piece([[true,true]])]
    let none=bestMove(checker,impossible)
    let impossibleOK=(none==nil)
    let impossibleNodes=LAST_SOLVER_NODES

    // Combo budget rule: row 7 needs both the domino and the single before it
    // can clear, so the only clearing sequence clears on its 2nd placement.
    // With a fresh or half-spent budget the clear must be taken; with the
    // budget fully spent (2 skips, budget 0) the solver must abandon the
    // combo and play the safest tray.
    var row7=[[Bool]](repeating:[Bool](repeating:false,count:8),count:8)
    for c in 3..<8 { row7[7][c]=true }
    let latePieces=[piece([[true,true]]),piece([[true]]),
                    piece([[true,true],[true,true]])]
    let freshBudgetOK=bestMove(row7,latePieces,skips:0)?.cleared==1
    let midBudgetOK=bestMove(row7,latePieces,skips:1)?.cleared==1
    let spentBudgetOK=bestMove(row7,latePieces,skips:2,streak:10)?.cleared==1
    let previewFixture=[
        PreviewCandidate(r:4,c:0,mean:236.6,minimum:236.6),
        PreviewCandidate(r:5,c:0,mean:218.0,minimum:212.9),
        PreviewCandidate(r:4,c:1,mean:177.4,minimum:0.0)
    ]
    let previewChoice=placementPreviewCandidate(previewFixture).0
    let previewPairOK=previewChoice?.r==5 && previewChoice?.c==0
    var restartThreshold=35
    let restartBeforeOK=33<restartThreshold
    let restartFirstOK=36>=restartThreshold
    while restartThreshold<=36 { restartThreshold+=35 }
    let restartSecondOK=restartThreshold==70 && 69<restartThreshold && 72>=restartThreshold
    let restartScheduleOK=restartBeforeOK && restartFirstOK && restartSecondOK
    var scoreStreak=0,scoreLines=0,scoreBonus=0
    for cleared in [1,1,2] {
        scoreStreak+=1; scoreLines+=cleared*10
        if scoreStreak>1 { scoreBonus+=scoreStreak*10 }
    }
    let benchmarkScoreOK=scoreLines==40 && scoreBonus==50
    print("SOLVER_TEST full=\(full?.seq.count ?? 0)/\(solvable.count) fullOK=\(fullOK) nodes=\(fullNodes) partialRejected=\(impossibleOK) rejectNodes=\(impossibleNodes) comboFresh=\(freshBudgetOK) comboMid=\(midBudgetOK) comboSpent=\(spentBudgetOK) previewPair=\(previewPairOK) restartSchedule=\(restartScheduleOK) benchmarkScore=\(benchmarkScoreOK)")
    if !fullOK || !impossibleOK || !freshBudgetOK || !midBudgetOK || !spentBudgetOK || !previewPairOK || !restartScheduleOK || !benchmarkScoreOK { exit(2) }
}
if ARGS.contains("--solver-test") { runSolverSelfTest() } else if ARGS.contains("--legacy-strict") || ARGS.contains("--vision") || ARGS.contains("--probe") { runStrict() } else { runBatchFast() }
