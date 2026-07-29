//
//  ViewController.swift
//  filego
//
//  Created by 赖恩光 on 2026/7/29.
//

import UIKit

final class ViewController: UIViewController {

    private let imageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "globe"))
        imageView.tintColor = .tintColor
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Hello, world!"
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        let stackView = UIStackView(arrangedSubviews: [imageView, titleLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            stackView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
}
