import Cocoa
import Metal

class MetalView: NSView {
    lazy var metalLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = true
        layer.frame = self.bounds
        return layer
    }()

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { fatalError("GPU not available") }

        layer = metalLayer
        metalLayer.device = device!

        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        commandQueue = queue

        let metalShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
            float2 positions[6] = {
                float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                float2(-1.0,  1.0), float2(1.0, -1.0), float2(1.0, 1.0)
            };

            float2 texCoords[6] = {
                float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
                float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
            };

            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 fragment_edr(VertexOut in [[stage_in]]) {
            const float bandValues[] = {
                0.0, 16.0, 
                0.0, 8.0, 
                0.0, 4.0, 
                0.0, 2.0, 
                0.0, 1.0, 
                0.0, 0.5, 
                0.0, 0.25, 
                0.0, 0.125, 
                0.0, 0.0625, 
                0.0, 0.03125, 
                0.0, 0.015625, 
                0.0, 0.0078125, 
                0.0
            };
            const int bandCount = sizeof(bandValues) / sizeof(bandValues[0]);
            float bandWidth = 1.0 / float(bandCount);

            if (in.texCoord.y > 0.1 && in.texCoord.y < 0.6) {
                int bandIndex = int(floor(in.texCoord.x / bandWidth));
                bandIndex = clamp(bandIndex, 0, bandCount - 1);
                float luminance = bandValues[bandIndex];
                return float4(luminance, luminance, luminance, 1.0);
            } else if (in.texCoord.y > 0.7 && in.texCoord.y < 0.9) {
                float luminance = in.texCoord.x * 16;
                return float4(luminance, luminance, luminance, 1.0);
            } else {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
        }
        """

        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "vertex_main") else {
                fatalError("Failed to find vertex function")
            }

            guard let fragmentFunction = library.makeFunction(name: "fragment_edr") else {
                fatalError("Failed to find fragment function")
            }
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create Metal library: \(error)")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        render()
    }

    func render() {
        guard let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        if let colorAttachment = renderPassDescriptor.colorAttachments[0] {
            colorAttachment.texture = drawable.texture
            colorAttachment.loadAction = .clear
            colorAttachment.storeAction = .store
        }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var metalView: MetalView!
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func registerForScreenParameterChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    @objc func screenParametersDidChange(notification: Notification) {
        if let mainScreen = NSScreen.main {
            let potentialMaxEDRValue = mainScreen.maximumExtendedDynamicRangeColorComponentValue
            if potentialMaxEDRValue > 1.0 {
                print("The display now supports EDR values (potential max value: \(potentialMaxEDRValue)).")
            } else {
                print("The display now supports only SDR values.")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerForScreenParameterChanges()
        if let mainScreen = NSScreen.main {
            let potentialMaxEDRValue = mainScreen.maximumPotentialExtendedDynamicRangeColorComponentValue
            print("Main Screen EDR Support Information:")
            if potentialMaxEDRValue > 1.0 {
                print("The display supports EDR values (potential max value: \(potentialMaxEDRValue)).")
            } else {
                print("The display supports only SDR values.")
            }

            let screenSize = mainScreen.frame.size
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: screenSize.width / 2, height: screenSize.height / 2),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
            window.title = "HDR Chart"
            window.makeKeyAndOrderFront(nil)

            metalView = MetalView(frame: window.contentView!.bounds)
            metalView.autoresizingMask = [.width, .height]
            window.contentView = metalView
            metalView.render()
        } else {
            print("No main screen found.")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
