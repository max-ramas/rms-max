@_exported import LiveKitWebRTC

// LiveKit builds WebRTC with an "LK" ObjC class prefix; keep the standard names in our code.
public typealias RTCAudioTrack = LKRTCAudioTrack
public typealias RTCCVPixelBuffer = LKRTCCVPixelBuffer
public typealias RTCCameraVideoCapturer = LKRTCCameraVideoCapturer
public typealias RTCConfiguration = LKRTCConfiguration
public typealias RTCDataBuffer = LKRTCDataBuffer
public typealias RTCDataChannel = LKRTCDataChannel
public typealias RTCDataChannelConfiguration = LKRTCDataChannelConfiguration
public typealias RTCDataChannelDelegate = LKRTCDataChannelDelegate
public typealias RTCDefaultVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory
public typealias RTCDefaultVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory
public typealias RTCIceCandidate = LKRTCIceCandidate
public typealias RTCIceConnectionState = LKRTCIceConnectionState
public typealias RTCIceGatheringState = LKRTCIceGatheringState
public typealias RTCIceServer = LKRTCIceServer
public typealias RTCMediaConstraints = LKRTCMediaConstraints
public typealias RTCMediaStream = LKRTCMediaStream
public typealias RTCMediaStreamTrack = LKRTCMediaStreamTrack
public typealias RTCPeerConnection = LKRTCPeerConnection
public typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
public typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
public typealias RTCPeerConnectionState = LKRTCPeerConnectionState
public typealias RTCRtpReceiver = LKRTCRtpReceiver
public typealias RTCRtpSender = LKRTCRtpSender
public typealias RTCRtpTransceiver = LKRTCRtpTransceiver
public typealias RTCSdpType = LKRTCSdpType
public typealias RTCSessionDescription = LKRTCSessionDescription
public typealias RTCSignalingState = LKRTCSignalingState
public typealias RTCStatisticsReport = LKRTCStatisticsReport
public typealias RTCVideoCapturer = LKRTCVideoCapturer
public typealias RTCVideoFrame = LKRTCVideoFrame
public typealias RTCVideoRenderer = LKRTCVideoRenderer
public typealias RTCVideoSource = LKRTCVideoSource
public typealias RTCVideoTrack = LKRTCVideoTrack
/// Metal renderer — LiveKit ships it for both UIKit and AppKit.
public typealias RTCMTLVideoView = LKRTCMTLVideoView
public typealias RTCIODevice = LKRTCIODevice
public typealias RTCAudioDeviceModule = LKRTCAudioDeviceModule
public typealias RTCFrameCryptor = LKRTCFrameCryptor
public typealias RTCFrameCryptorKeyProvider = LKRTCFrameCryptorKeyProvider
public typealias RTCFrameCryptorDelegate = LKRTCFrameCryptorDelegate
public typealias RTCFrameCryptorState = LKRTCFrameCryptorState
public typealias RTCVideoCapturerDelegate = LKRTCVideoCapturerDelegate
public typealias RTCRtpEncodingParameters = LKRTCRtpEncodingParameters
#if os(iOS)
public typealias RTCAudioSession = LKRTCAudioSession
#else
public typealias RTCDesktopCapturer = LKRTCDesktopCapturer
public typealias RTCDesktopSource = LKRTCDesktopSource
public typealias RTCDesktopCapturerDelegate = LKRTCDesktopCapturerDelegate
public typealias RTCDesktopMediaList = LKRTCDesktopMediaList
public typealias RTCDesktopMediaListDelegate = LKRTCDesktopMediaListDelegate
#endif

@discardableResult
func RTCInitializeSSL() -> Bool { LKRTCInitializeSSL() }
