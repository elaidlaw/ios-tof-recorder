//
//  ContentView.swift
//  ToFRecorder
//
//  Created by Eliot Laidlaw on 3/10/21.
//

import SwiftUI
import RealityKit
import VideoToolbox
import ARKit
import Compression

extension UIImage {
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage1: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage1)

        guard let cgImage = cgImage1 else {
            return nil
        }

        self.init(cgImage: cgImage)
    }
}

struct ContentView : View {
    @State private var takePicture = false
    @State private var count: Int = 1
    
    var body: some View {
        return ZStack(alignment: /*@START_MENU_TOKEN@*/Alignment(horizontal: .center, vertical: .center)/*@END_MENU_TOKEN@*/, content: {
            ARViewContainer(takePicture: self.$takePicture, count: self.$count)
            Button(action: {
                self.takePicture = !self.takePicture
            }) {
                Text("Take picture")
            } .buttonStyle(PlainButtonStyle())
        })
    }
}

class DepthCapture {
    let kErrorDomain = "DepthCapture"
    let maxNumberOfFrame = 250
    lazy var bufferSize = 640 * 480 * 2 * maxNumberOfFrame  // maxNumberOfFrame frames
    var dstBuffer: UnsafeMutablePointer<UInt8>?
    var frameCount: Int64 = 0
    var outputURL: URL?
    var compresserPtr: UnsafeMutablePointer<compression_stream>?
    var file: FileHandle?

    // All operations handling the compresser oobjects are done on the
    // porcessingQ so they will happen sequentially
    var processingQ = DispatchQueue(label: "compression",
                                    qos: .userInteractive)


    func reset() {
        frameCount = 0
        outputURL = nil
        if self.compresserPtr != nil {
            //free(compresserPtr!.pointee.dst_ptr)
            compression_stream_destroy(self.compresserPtr!)
            self.compresserPtr = nil
        }
        if self.file != nil {
            self.file!.closeFile()
            self.file = nil
        }
    }
    func prepareForRecording(name: String) {
        reset()
        // Create the output zip file, remove old one if exists
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        self.outputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent(name))
        FileManager.default.createFile(atPath: self.outputURL!.path, contents: nil, attributes: nil)
        self.file = FileHandle(forUpdatingAtPath: self.outputURL!.path)
        if self.file == nil {
            NSLog("Cannot create file at: \(self.outputURL!.path)")
            return
        }

        // Init the compression object
        compresserPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        compression_stream_init(compresserPtr!, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        compresserPtr!.pointee.dst_ptr = dstBuffer!
        //defer { free(bufferPtr) }
        compresserPtr!.pointee.dst_size = bufferSize


    }
    func flush() {
        //let data = Data(bytesNoCopy: compresserPtr!.pointee.dst_ptr, count: bufferSize, deallocator: .none)
        let nBytes = bufferSize - compresserPtr!.pointee.dst_size
        print("Writing \(nBytes)")
        let data = Data(bytesNoCopy: dstBuffer!, count: nBytes, deallocator: .none)
        self.file?.write(data)
    }

    func startRecording(name: String) throws {
        processingQ.async {
            self.prepareForRecording(name: name)
        }
    }
    func addPixelBuffers(pixelBuffer: CVPixelBuffer) {
        processingQ.async {
            if self.frameCount >= self.maxNumberOfFrame {
                // TODO now!! flush when needed!!!
                print("MAXED OUT")
                return
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let add : UnsafeMutableRawPointer = CVPixelBufferGetBaseAddress(pixelBuffer)!
            self.compresserPtr!.pointee.src_ptr = UnsafePointer<UInt8>(add.assumingMemoryBound(to: UInt8.self))
            let height = CVPixelBufferGetHeight(pixelBuffer)
            self.compresserPtr!.pointee.src_size = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
            let flags = Int32(0)
            let compression_status = compression_stream_process(self.compresserPtr!, flags)
            if compression_status != COMPRESSION_STATUS_OK {
                NSLog("Buffer compression retured: \(compression_status)")
                return
            }
            if self.compresserPtr!.pointee.src_size != 0 {
                NSLog("Compression lib didn't eat all data: \(compression_status)")
                return
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            // TODO(eyal): flush when needed!!!
            self.frameCount += 1
            print("handled \(self.frameCount) buffers")
        }
    }
    func finishRecording(success: @escaping ((URL) -> Void)) throws {
        processingQ.async {
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            self.compresserPtr!.pointee.src_size = 0
            //compresserPtr!.pointee.src_ptr = UnsafePointer<UInt8>(0)
            let compression_status = compression_stream_process(self.compresserPtr!, flags)
            if compression_status != COMPRESSION_STATUS_END {
                NSLog("ERROR: Finish failed. compression retured: \(compression_status)")
                return
            }
            self.flush()
            DispatchQueue.main.sync {
                success(self.outputURL!)
            }
            self.reset()
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var takePicture: Bool
    @Binding var count: Int
    
    func makeUIView(context: Context) -> ARView {
        
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        print(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
        config.frameSemantics.insert(.sceneDepth)
        // Run the configuration to effect a frame semantics change.
        arView.session.run(config)
        
        return arView
        
    }
    
    func takePic(uiView: ARView, n: Int) {
        if (n > 0) {
            let seconds = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let session = uiView.session
                if let frame = session.currentFrame {
                    let color = frame.capturedImage
                    if let uiColor = UIImage(pixelBuffer: color) {                UIImageWriteToSavedPhotosAlbum(uiColor, nil, nil, nil)
                    }
                    print(frame.sceneDepth == nil)
                    if let depth = frame.sceneDepth {
                        print("saving depth")
                        let dc = DepthCapture()
                        do {
                            try dc.startRecording(name: "Depth" + String(self.count) + "_" + String(n))
                            dc.addPixelBuffers(pixelBuffer: depth.depthMap)
                            try dc.finishRecording(success: { url in print(url) })
                        } catch {
                            print("error")
                        }
                    }
                    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
                    let outputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent("Pose" + String(self.count) + "_" + String(n) + ".txt"))
                    let pose: String = frame.camera.transform.debugDescription +  "\n" + String(Date().timeIntervalSinceReferenceDate)
                    do {
                        try pose.write(to: outputURL, atomically: true, encoding: String.Encoding.utf8)
                    } catch {
                        print("error")
                    }
                }
                
                takePic(uiView: uiView, n: n - 1)
            }
        }
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        if (takePicture) {
            takePic(uiView: uiView, n: 40)
            
            DispatchQueue.main.async {
                takePicture = false
                count += 1
            }
        }
    }
    
}

#if DEBUG
struct ContentView_Previews : PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
