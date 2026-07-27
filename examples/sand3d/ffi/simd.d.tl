local record simd
  record Features
    avx2: boolean
    fma: boolean
    vecsize: integer
  end

  features: function(): Features
  fma: function(any, any, any): any
  lt: function(any, any): any
  ge: function(any, any): any
  movemask: function(any): integer
end

return simd
