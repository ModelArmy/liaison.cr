require "../spec_helper"

# The tool-call argument rule, tested away from any protocol.
#
# Four exporters and one assembler read arguments through this. Each also has
# an example in its own protocol's spec, proving it does; this file pins what
# the rule is.

private def read(json : String) : M::Object
  P::Arguments.read(json, "test", "get_weather")
end

describe Liaison::Protocol::Arguments do
  describe ".read" do
    it "reads an object, nested values included" do
      arguments = read(%({"city":"Paris","days":3,"metric":true,"tags":["a",null],"at":{"lat":48.9}}))

      arguments["city"].should eq "Paris"
      arguments["days"].should eq 3
      arguments["metric"].should eq true
      arguments["tags"].should eq ["a", nil]
      arguments["at"].should eq({"lat" => 48.9})
    end

    it "reads blank text as a call with no arguments" do
      read("").should be_empty
      read("  \n").should be_empty
    end

    it "reads an empty object as a call with no arguments" do
      read("{}").should be_empty
    end

    it "raises on text that is not JSON, naming the source and the tool" do
      error = expect_raises(P::MalformedResponseError) { read(%({"city":"Par)) }

      error.provider.should eq "test"
      error.message.to_s.should contain "`get_weather`"
    end

    it "raises on JSON that is not an object" do
      [%(["Paris"]), %("Paris"), "42", "true", "null"].each do |json|
        expect_raises(P::MalformedResponseError, /not a JSON object/) { read(json) }
      end
    end
  end

  describe ".object" do
    it "applies the same rule, leaving values as JSON" do
      P::Arguments.object(%({"city":"Paris"}), "test", "f")["city"].as_s.should eq "Paris"
      P::Arguments.object("", "test", "f").should be_empty

      expect_raises(P::MalformedResponseError) { P::Arguments.object("[]", "test", "f") }
    end
  end
end
