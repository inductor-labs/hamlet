describe "text", ->
  it "should render a simple line of text", ->
    template = makeTemplate """
      span
        | text
    """

    element = template()
    assert.equal element.textContent, "text\n"

  it "should do inline text", ->
    template = makeTemplate """
      p
        | hello I am a cool paragraph
        | with lots of text and stuff
        | ain't it rad?
    """

    element = template()

    assert.equal element.textContent, """
      hello I am a cool paragraph
      with lots of text and stuff
      ain't it rad?

    """
