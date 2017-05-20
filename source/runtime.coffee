"use strict"

Observable = require "o_0"

# To clean up listeners we need to keep a map of dom elements and what listeners are bound to them
# when we dispose an element we must traverse its children and clean them up too
# After we remove the listeners we must then remove the element from the map

elementCleaners = new Map

# TODO: If we remove an element that has a child element that should be retain
# we'll run all its cleaners here when we shouldn't. We need a way to mark an
# element as retained and to skip disposing it if we want to reuse it with
# separate logic.
dispose = (element) ->
  # Recurse into children
  children = element.children
  if children?
    Array::forEach.call children, dispose

  elementCleaners.get(element)?.forEach (cleaner) ->
    cleaner()
    elementCleaners.delete(element)
    return
  return

attachCleaner = (element, cleaner) ->
  cleaners = elementCleaners.get(element)
  if cleaners
    cleaners.push cleaner
  else
    elementCleaners.set element, [cleaner]
  return

valueBind = (element, value, context) ->
  switch element.nodeName
    when "SELECT"
      element.oninput = element.onchange = ->
        {value:optionValue, _value} = @children[@selectedIndex]

        value?(_value or optionValue)
        return

      bindObservable element, value, context, (newValue) ->
        # This is so we can hold a non-string object as a value of the select element
        element._value = newValue

        if (options = element._options)
          if newValue.value?
            # TODO: Handle observable value attributes
            element.value = newValue.value?() or newValue.value
          else
            element.selectedIndex = valueIndexOf options, newValue
        else
          element.value = newValue
        return

    else
      # Because firing twice with the same value is idempotent just binding both
      # oninput and onchange handles the widest range of inputs and browser
      # inconsistencies.
      element.oninput = element.onchange = ->
        value?(element.value)
        return

      bindObservable element, value, context, (newValue) ->
        unless element.value is newValue
          element.value = newValue
        return

  return

specialBindings =
  INPUT:
    checked: (element, value, context) ->
      element.onchange = ->
        value? element.checked
        return

      bindObservable element, value, context, (newValue) ->
        element.checked = newValue
        return
  SELECT:
    options: (element, values, context) ->
      bindObservable element, values, context, (values) ->
        empty(element)
        element._options = values

        # TODO: Handle key: value... style options
        values.map (value, index) ->
          option = createElement("option")
          option._value = value
          if typeof value is "object"
            optionValue = value?.value or index
          else
            optionValue = value.toString()

          bindObservable option, optionValue, value, (newValue) ->
            option.value = newValue
            return

          optionName = value?.name or value
          bindObservable option, optionName, value, (newValue) ->
            option.textContent = newValue
            return

          element.appendChild option
          element.selectedIndex = index if value is element._value

          return option
        return

observeAttribute = (element, context, name, value) ->
  {nodeName} = element

  # TODO: Consolidate special bindings better than if/else
  if name is "value"
    valueBind(element, value)
  else if binding = specialBindings[nodeName]?[name]
    binding(element, value, context)
  # Straight up onclicks, etc.
  else if name.match(/^on/) and name of element
    bindEvent(element, name, value, context)
  # Handle click=@method
  else if "on#{name}" of element
    bindEvent(element, "on#{name}", value, context)
  else
    bindObservable element, value, context, (newValue) ->
      if newValue? and newValue != false
        element.setAttribute name, newValue
      else
        element.removeAttribute name
      return
  return

observeAttributes = (element, context, attributes) ->
  Object.keys(attributes).forEach (name) ->
    observeAttribute element, context, name, attributes[name]
    return
  return

# To bind an observable precisely to the site where it is
# and to be able to clean up we need to create a fresh
# Observable stack. Since the observable re-computes
# when any of its dependencies change it will refresh the update
# with the new value. To clean up we release the dependencies of
# our computed observable. We store the observables to clean up
# on a map keyed by the element.
bindObservable = (element, value, context, update) ->
  observable = Observable ->
    update get value, context
    return

  attachCleaner element, observable.releaseDependencies
  return

bindEvent = (element, name, fn, context) ->
  element[name] = fn?.bind(context)
  return

id = (element, context, sources) ->
  lastId = ->
    [..., last] = splat sources, context
    return last

  bindObservable element, lastId, context, update = (newId) ->
    element.id = newId
    return

  return

classes = (element, context, sources) ->
  classNames = ->
    splat(sources, context).join(" ")

  bindObservable element, classNames, context, (classNames) ->
    element.className = classNames
    return

  return

observeContent = (element, context, contentFn) ->
  # TODO: Don't even try to observe contents for empty functions
  content = ->
    contents = []

    contentFn.call context,
      buffer: bufferTo(context, contents)
      element: makeElement

    return contents

  append = (item) ->
    if !item? # Skip nulls
    else if typeof item.forEach is "function"
      item.forEach append
    else if item instanceof Node
      element.appendChild item
    else
      element.appendChild document.createTextNode item
    return

  bindObservable element, content, context, (contents) ->
    # TODO: Zipper merge optimization to more efficiently modify the DOM
    empty element

    contents.forEach append
    return

  return

bufferTo = (context, collection) ->
  (content) ->
    collection.push get content, context

    return

makeElement = (name, context, attributes, fn) ->
  element = createElement name

  if attributes.id?
    id(element, context, attributes.id)
    delete attributes.id

  if attributes.class?
    classes(element, context, attributes.class)
    delete attributes.class

  observeAttributes(element, context, attributes)

  # TODO: Maybe have a flag for element contents that are created from
  # attributes rather than special casing this
  unless element.nodeName is "SELECT"
    observeContent(element, context, fn)

  return element

Runtime = (context) ->
  self =
    # TODO: May be able to consolidate some of this with the
    # element contents stuff
    buffer: (content) ->
      if self.root
        throw new Error "Cannot have multiple root elements"

      self.root = content
      return

    element: makeElement

    filter: (name, content) ->
      ; # TODO self.filters[name](content)

  return self

Runtime.VERSION = require("../package.json").version
Runtime.Observable = Observable
Runtime._elementCleaners = elementCleaners
Runtime._dispose = dispose
module.exports = Runtime

createElement = (name) ->
  document.createElement name

empty = (node) ->
  while child = node.firstChild
    node.removeChild(child)
    dispose(child)

  return

# A helper to find the index of a value in an array of options
# when the array may contain actual objects or strings, numbers, etc.

# NOTE: This may be too complicated, the core issue is that anything coming from an input
# will be a string, and anything coming from a regular observable can be any object type.
# Possible solutions:
#   Typed observables that auto-convert strings to the correct type.
#   OR
#   Always compare non-object inputs as strings.
valueIndexOf = (options, value) ->
  if typeof value is "object"
    options.indexOf(value)
  else
    options.map (option) ->
      option.toString()
    .indexOf value.toString()

splat = (sources, context) ->
  sources.map (source) ->
    get source, context
  .reduce (a, b) ->
    a.concat get b
  , []
  .filter (x) -> x?

get = (x, context) ->
  if typeof x is 'function'
    x.call(context)
  else
    x
