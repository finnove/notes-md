require 'zlib'

# Builds ZDATA the way Apple Notes stores it: gzip of protobuf
# NoteStoreProto(2) → Document(3) → Note { note_text=2, attribute_run=5 }.
module Proto
  module_function

  def varint(n)
    n += 1 << 64 if n.negative?
    out = +""
    loop do
      byte = n & 0x7f
      n >>= 7
      if n.zero?
        out << byte.chr
        return out.b
      end
      out << (byte | 0x80).chr
    end
  end

  def int(field, n)
    varint(field << 3) + varint(n)
  end

  def bytes(field, str)
    str = str.b
    varint((field << 3) | 2) + varint(str.bytesize) + str
  end

  # items: [[text, :check | :done | :plain | :dash | :bare, attachment_id?]] — :bare has
  # no paragraph style. With an attachment id the text must start with U+FFFC; the
  # first character then gets its own run with attachment_info (field 12).
  def zdata(items)
    text = items.map { |t, _| "#{t}\n" }.join
    runs = items.map { |t, kind, att|
      len = "#{t}\n".encode("UTF-16LE").bytesize / 2
      style = case kind
              when :check, :done
                int(1, 103) + bytes(5, bytes(1, "uuid") + int(2, kind == :done ? 1 : 0))
              when :dash then int(1, 101)
              else int(1, -1)
              end
      if att
        bytes(5, int(1, 1) + bytes(2, style) + bytes(12, bytes(1, att))) +
          bytes(5, int(1, len - 1) + bytes(2, style))
      elsif kind == :bare
        bytes(5, int(1, len))
      else
        bytes(5, int(1, len) + bytes(2, style))
      end
    }.join
    note = bytes(2, text) + runs
    doc = int(2, 0) + bytes(3, note)
    Zlib.gzip(bytes(2, doc))
  end
end
