// Copyright (c) Kyutai, all rights reserved.
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

import MLX
import MLXFast
import MLXNN

public enum Norm {
    case layerNorm
    case rmsNorm
}

public enum PositionalEmbedding {
    case none
    case rope
}

public struct TransformerConfig {
    public var dModel: Int
    public var numHeads: Int
    public var numLayers: Int
    public var causal: Bool
    public var normFirst: Bool
    public var biasFF: Bool
    public var biasAttn: Bool
    public var layerScale: Float?
    public var positionalEmbedding: PositionalEmbedding
    public var useConvBias: Bool
    public var gating: Bool
    public var norm: Norm
    public var context: Int
    public var maxPeriod: Int
    public var maxSeqLen: Int
    public var kvRepeat: Int
    public var dimFeedForward: Int
    public var convLayout: Bool

    public func headDim() -> Int {
        self.dModel / self.numHeads
    }

    public static func v1_7b() -> TransformerConfig {
        TransformerConfig(
            dModel: 4096,
            numHeads: 32,
            numLayers: 32,
            causal: true,
            normFirst: true,
            biasFF: false,
            biasAttn: false,
            layerScale: nil,
            positionalEmbedding: .rope,
            useConvBias: false,
            gating: true,
            norm: .rmsNorm,
            context: 3000,
            maxPeriod: 10000,
            maxSeqLen: 4096,
            kvRepeat: 1,
            dimFeedForward: 4096 * 4,
            convLayout: false
        )
    }
}

private class MlpGating: Module, UnaryLayer {
    @ModuleInfo(key: "linear_in") var linear_in: Linear
    @ModuleInfo(key: "linear_out") var linear_out: Linear

    init(_ cfg: TransformerConfig) {
        let hidden =
            cfg.dimFeedForward == 4 * cfg.dModel ? 11 * cfg.dModel / 4 : 2 * cfg.dimFeedForward / 3
        self._linear_in.wrappedValue = Linear(cfg.dModel, 2 * hidden, bias: cfg.biasFF)
        self._linear_out.wrappedValue = Linear(hidden, cfg.dModel, bias: cfg.biasFF)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let x = linear_in(x)
        let (B, T) = (x.dim(0), x.dim(1))
        let x_reshaped = x.reshaped(B, T, 2, -1)
        return linear_out(silu(x_reshaped[0..., 0..., 0]) * x_reshaped[0..., 0..., 1])
    }
}

private class MlpNoGating: Module, UnaryLayer {
    @ModuleInfo(key: "linear1") var linear1: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear

    init(_ cfg: TransformerConfig) {
        self._linear1.wrappedValue = Linear(cfg.dModel, cfg.dimFeedForward, bias: cfg.biasFF)
        self._linear2.wrappedValue = Linear(cfg.dimFeedForward, cfg.dModel, bias: cfg.biasFF)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(geluApproximate(linear1(x)))
    }
}

private class Attention: Module {
    let cfg: TransformerConfig
    let scale: Float
    let rope: RoPE?

    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ cfg: TransformerConfig) {
        self.cfg = cfg
        self.scale = 1.0 / sqrt(Float(cfg.headDim()))
        let numKV = cfg.numHeads / cfg.kvRepeat
        let outDim = cfg.dModel + 2 * numKV * cfg.dModel / cfg.numHeads
        self._inProj.wrappedValue = Linear(cfg.dModel, outDim, bias: cfg.biasAttn)
        self._outProj.wrappedValue = Linear(cfg.dModel, cfg.dModel, bias: cfg.biasAttn)
        self.rope =
            switch cfg.positionalEmbedding {
            case .none: nil
            case .rope:
                RoPE(dimensions: cfg.headDim(), traditional: true, base: Float(cfg.maxPeriod))
            }
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache?) -> MLXArray {
        let (B, T, H) = (x.dim(0), x.dim(1), x.dim(2))
        let qkv = inProj(x).reshaped(B, T, 3, cfg.numHeads, cfg.headDim())
        var q = qkv[0..., 0..., 0].transposed(0, 2, 1, 3)
        var k = qkv[0..., 0..., 1].transposed(0, 2, 1, 3)
        var v = qkv[0..., 0..., 2].transposed(0, 2, 1, 3)
        if let rope {
            let offset = cache?.offset ?? 0
            q = rope(q, offset: offset)
            k = rope(k, offset: offset)
        }
        if let cache {
            (k, v) = cache.update(keys: k, values: v)
        }
        let k_len = k.dim(2)
        let k_target_len = T + min(self.cfg.context, k_len - T)
        if k_target_len < k_len {
            let offset = k_len - k_target_len
            k = k[0..., 0..., offset...]
            v = v[0..., 0..., offset...]
        }
        let x = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: self.scale, mask: mask
        ).transposed(0, 2, 1, 3).reshaped(B, T, H)
        return outProj(x)
    }
}

private class TransformerLayer: Module {
    @ModuleInfo(key: "gating") var gating: UnaryLayer
    @ModuleInfo(key: "norm1") var norm1: UnaryLayer
    @ModuleInfo(key: "norm2") var norm2: UnaryLayer
    @ModuleInfo(key: "self_attn") var selfAttn: Attention

    init(_ cfg: TransformerConfig) {
        self._gating.wrappedValue = cfg.gating ? MlpGating(cfg) : MlpNoGating(cfg)
        self._norm1.wrappedValue =
            switch cfg.norm {
            case .layerNorm:
                LayerNorm(dimensions: cfg.dModel, eps: 1e-5)
            case .rmsNorm: RMSNorm(dimensions: cfg.dModel, eps: 1e-8)
            }
        self._norm2.wrappedValue =
            switch cfg.norm {
            case .layerNorm:
                LayerNorm(dimensions: cfg.dModel, eps: 1e-5)
            case .rmsNorm: RMSNorm(dimensions: cfg.dModel, eps: 1e-8)
            }
        self._selfAttn.wrappedValue = Attention(cfg)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache) -> MLXArray {
        let x = x + selfAttn(norm1(x), mask: mask, cache: cache)
        return x + gating(norm2(x))
    }
}

public class Transformer: Module {
    let cfg: TransformerConfig
    private let layers: [TransformerLayer]

    public init(_ cfg: TransformerConfig) {
        self.cfg = cfg
        self.layers = (0..<cfg.numLayers).map { _ in TransformerLayer(cfg) }
    }

    public func callAsFunction(_ x: MLXArray, cache: [KVCache]) -> MLXArray {
        var x = x
        let mask = createAttentionMask(h: x, cache: cache)
        for (layer, c) in zip(self.layers, cache) {
            x = layer(x, mask: mask, cache: c)
        }
        return x
    }

    public func makeCache() -> [KVCache] {
        let kvHeads = cfg.numHeads / cfg.kvRepeat
        return (0..<cfg.numLayers).map { _ in
            KVCacheSimple(headDim: .init(cfg.headDim()), kvHeads: kvHeads)
        }
    }
}
