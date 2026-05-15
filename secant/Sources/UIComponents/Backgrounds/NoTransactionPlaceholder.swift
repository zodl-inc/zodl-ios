//
//  NoTransactionPlaceholder.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-22-2025.
//

import SwiftUI
import UIKit

struct ShimmerConfiguration {
    let gradient: Gradient
    let initialLocation: (start: UnitPoint, end: UnitPoint)
    let finalLocation: (start: UnitPoint, end: UnitPoint)
    let duration: TimeInterval
    let opacity: Double
    static let `default` = ShimmerConfiguration(
        gradient: Gradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .white, location: 0.3),
            .init(color: .white, location: 0.7),
            .init(color: .black, location: 1),
        ]),
        initialLocation: (start: UnitPoint(x: -1, y: 0.5), end: .leading),
        finalLocation: (start: .trailing, end: UnitPoint(x: 2, y: 0.5)),
        duration: 1.5,
        opacity: 0.15
    )
}

struct NoTransactionPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    let isShimmerOn: Bool
    
    init(_ isShimmerOn: Bool = false) {
        self.isShimmerOn = isShimmerOn
    }
    
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .shimmer(isShimmerOn).clipShape(Circle())
                .frame(width: 40, height: 40)
                .zForegroundColor(Design.Surfaces.bgSecondary)
                .padding(.trailing, 16)
            
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: Design.Radius._md)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(isShimmerOn).clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(width: 86, height: 14)
                
                RoundedRectangle(cornerRadius: Design.Radius._md)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(isShimmerOn).clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(width: 64, height: 14)
            }
            
            Spacer()
            
            RoundedRectangle(cornerRadius: Design.Radius._md)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(isShimmerOn).clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(width: 32, height: 14)
        }
        .screenHorizontalPadding()
        .padding(.vertical, 12)
    }
}

class ShimmerCALayer: UIView {
    private var gradientLayer: CAGradientLayer?
    private let configuration: ShimmerConfiguration
    private var isAnimating = false
    
    init(configuration: ShimmerConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupLayer() {
        backgroundColor = UIColor.clear
        
        let gradient = CAGradientLayer()
        gradient.colors = configuration.gradient.stops.map { stop in
            // Convert SwiftUI Color to CGColor
            UIColor(stop.color).cgColor
        }
        
        gradient.locations = configuration.gradient.stops.map { stop in
            NSNumber(value: stop.location)
        }
        
        // Set initial positions (off-screen to the left)
        gradient.startPoint = CGPoint(x: -1, y: 0.5)
        gradient.endPoint = CGPoint(x: 0, y: 0.5)
        
        layer.addSublayer(gradient)
        gradientLayer = gradient
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = bounds
    }
    
    func startAnimation() {
        guard !isAnimating, let gradientLayer = gradientLayer else { return }
        
        isAnimating = true
        
        // Animate start point
        let startPointAnimation = CABasicAnimation(keyPath: "startPoint")
        startPointAnimation.fromValue = CGPoint(x: -1, y: 0.5)
        startPointAnimation.toValue = CGPoint(x: 1, y: 0.5)
        
        // Animate end point
        let endPointAnimation = CABasicAnimation(keyPath: "endPoint")
        endPointAnimation.fromValue = CGPoint(x: 0, y: 0.5)
        endPointAnimation.toValue = CGPoint(x: 2, y: 0.5)
        
        // Group animations
        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [startPointAnimation, endPointAnimation]
        animationGroup.duration = configuration.duration
        animationGroup.repeatCount = .infinity
        animationGroup.timingFunction = CAMediaTimingFunction(name: .linear)
        
        gradientLayer.add(animationGroup, forKey: "shimmer")
    }
    
    func stopAnimation() {
        guard isAnimating else { return }
        
        isAnimating = false
        gradientLayer?.removeAnimation(forKey: "shimmer")
        
        // Reset to initial position
        gradientLayer?.startPoint = CGPoint(x: -1, y: 0.5)
        gradientLayer?.endPoint = CGPoint(x: 0, y: 0.5)
    }
}

struct DirectCAShimmerView: View {
    let isActive: Bool
    let configuration: ShimmerConfiguration
    
    var body: some View {
        GeometryReader { geometry in
            CALayerView(isActive: isActive, configuration: configuration, size: geometry.size)
        }
    }
}

struct CALayerView: UIViewRepresentable {
    let isActive: Bool
    let configuration: ShimmerConfiguration
    let size: CGSize
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = CGRect(origin: .zero, size: size)
        gradientLayer.colors = configuration.gradient.stops.map { stop in
            UIColor(stop.color).cgColor
        }
        gradientLayer.locations = configuration.gradient.stops.map { stop in
            NSNumber(value: stop.location)
        }
        gradientLayer.startPoint = CGPoint(x: -1, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0, y: 0.5)
        
        view.layer.addSublayer(gradientLayer)
        
        // Store gradient layer reference
        view.layer.setValue(gradientLayer, forKey: "shimmerGradient")
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let gradientLayer = uiView.layer.value(forKey: "shimmerGradient") as? CAGradientLayer else {
            return
        }
        
        // Update frame
        gradientLayer.frame = CGRect(origin: .zero, size: size)
        
        if isActive {
            // Start animation if not already running
            if gradientLayer.animation(forKey: "shimmer") == nil {
                let startPointAnimation = CABasicAnimation(keyPath: "startPoint")
                startPointAnimation.fromValue = CGPoint(x: -1, y: 0.5)
                startPointAnimation.toValue = CGPoint(x: 1, y: 0.5)
                
                let endPointAnimation = CABasicAnimation(keyPath: "endPoint")
                endPointAnimation.fromValue = CGPoint(x: 0, y: 0.5)
                endPointAnimation.toValue = CGPoint(x: 2, y: 0.5)
                
                let animationGroup = CAAnimationGroup()
                animationGroup.animations = [startPointAnimation, endPointAnimation]
                animationGroup.duration = configuration.duration
                animationGroup.repeatCount = .infinity
                animationGroup.timingFunction = CAMediaTimingFunction(name: .linear)
                
                gradientLayer.add(animationGroup, forKey: "shimmer")
            }
        } else {
            // Stop animation
            gradientLayer.removeAnimation(forKey: "shimmer")
            gradientLayer.startPoint = CGPoint(x: -1, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: 0, y: 0.5)
        }
    }
}

extension View {
    func shimmer(_ active: Bool, configuration: ShimmerConfiguration = ShimmerConfiguration.default) -> some View {
        self.overlay(
            active ?
            DirectCAShimmerView(isActive: active, configuration: configuration)
                .opacity(configuration.opacity)
                .blendMode(.screen)
                .allowsHitTesting(false)
            : nil
        )
    }
}
