class Array
  def to_hash_by_key(key)
    self.reduce({}) do |acc_hash, item|
      acc_hash[item[key]] = item
      acc_hash
    end
  end
end

class Hash
  def deep_merge(other_hash)
    self.merge(other_hash) do |key, init_value, other_value|
      if init_value.kind_of?(Hash) && other_value.kind_of?(Hash)
        init_value.deep_merge(other_value)
      elsif init_value.kind_of?(Array) && other_value.kind_of?(Array)
        hashed_init_value = init_value.to_hash_by_key('kind')
        hashed_other_value = other_value.to_hash_by_key('kind')
        hashed_init_value.deep_merge(hashed_other_value).values
      else
        other_value
      end
    end
  end
end
