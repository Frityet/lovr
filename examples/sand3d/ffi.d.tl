local record ffi
  interface CData end
  interface Array<T> is {T}, CData end

  type CNamespace = {string: any}

  C: CNamespace
  os: string
  cdef: function(string)
  new: function<T>(string, ...: any): T
  cast: function<T>(any, any): T
  typeof: function(any, ...: any): any
  sizeof: function(any): integer
  fill: function(any, integer, ? integer)
  istype: function(any, any): boolean
end

return ffi
