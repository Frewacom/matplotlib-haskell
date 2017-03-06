# Matplotlib

[![Build Status](http://circleci-badges-max.herokuapp.com/img/abarbu/matplotlib-haskell/master?token=468e8942459ca5f34089fb5c29a478ffb6d531af)](https://circleci.com/gh/abarbu/matplotlib-haskell/tree/master)

Haskell bindings to Python's Matplotlib. It's high time that Haskell had a
fully-fledged plotting library!

![matplotlib contour plot](https://github.com/abarbu/matplotlib-haskell/raw/master/contour.png)

More info and docs forthcoming.

```haskell
import Matplotlib

onscreen $ contourF (\a b -> sin (degreesRadians a) + cos (degreesRadians b)) (-100) 100 (-200) 200 10
```
