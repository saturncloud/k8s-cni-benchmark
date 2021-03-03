# Benchmarking tools for Kubernetes CNIs


Updates made to run these benchmarks more generically, specifically for running on Saturn clusters

Example usage:

```sh
./bench.sh --protocols "TCP HTTP" --context mycluster --time 60 --tag aws-cni
./bench.sh --protocols "TCP HTTP" --context mycluster2 --time 60 --tag calico
...
```



The goal of this repository is to publish the scripts and tools used in the benchmark conducted by Alexis Ducastel (Twitter : [@infraBuilder](https://twitter.com/infraBuilder), Medium : [Alexis Ducastel](https://medium.com/@infrabuilder)).

An article has been published on Medium with the first results published on November 2018 : https://itnext.io/benchmark-results-of-kubernetes-network-plugins-cni-over-10gbit-s-network-36475925a560

Specials thanks to [@tgraf__](https://twitter.com/tgraf__) and [@martyns](https://twitter.com/martyns) for the monitoring fix applied before to push this repo.