//
//  main.swift
//  moshi-cli
//
//  Created by Laurent on 20/11/2024.
//

import Foundation
import MLX
import MLXNN
import MoshiLib

print("Hello, World!")

let arr = MLXArray(stride(from: Int32(2), through: 8, by: 2), [2, 2])

print(arr)
print(arr.dtype)
print(arr.shape)
print(arr.ndim)
print(arr.asType(.int64))

// print a row
print(arr[1])

// print a value
print(arr[0, 1].item(Int32.self))

let weights = try loadArrays(url: URL(fileURLWithPath: "model.safetensors"))
let parameters = ModuleParameters.unflattened(weights)
let cfg = TransformerConfig.v0_1()
let model = Transformer(cfg)
try model.update(parameters: parameters, verify: [.all])
eval(model)
print(model)
